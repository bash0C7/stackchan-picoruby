require "fileutils"

module DeviceLock
  class Timeout < StandardError; end

  DEFAULT_WAIT = 600
  NOTICE_EVERY = 30

  module_function

  def dir
    ENV["R2P2_DEVICE_LOCK_DIR"] || File.join(Dir.home, ".cache", "r2p2-device-locks")
  end

  def env_key(target)
    "R2P2_DEVICE_LOCK_HOLDER_#{target.upcase}"
  end

  def hold(target, root: dir, pid: Process.pid, env: ENV, **opts)
    acquired = acquire(target, root: root, pid: pid, env: env, **opts)
    at_exit { release(target, root: root, pid: pid, env: env) } if acquired
    acquired
  end

  def synchronize(target, root: dir, pid: Process.pid, env: ENV, **opts)
    acquired = acquire(target, root: root, pid: pid, env: env, **opts)
    yield
  ensure
    release(target, root: root, pid: pid, env: env) if acquired
  end

  def acquire(target, wait: (ENV["DEVICE_LOCK_WAIT"] || DEFAULT_WAIT).to_f, root: dir,
              pid: Process.pid, env: ENV, alive_fn: method(:alive?),
              sleep_fn: method(:sleep), now_fn: -> { Time.now }, out: $stderr)
    lock = File.join(root, "#{target}.lock")
    FileUtils.mkdir_p(root)
    deadline = now_fn.call + wait
    next_notice = now_fn.call

    loop do
      begin
        Dir.mkdir(lock)
        File.write(File.join(lock, "owner"), "#{pid} #{$PROGRAM_NAME}\n")
        env[env_key(target)] = pid.to_s
        return true
      rescue Errno::EEXIST
        owner_pid, owner_cmd = read_owner(lock)
        return false if owner_pid && env[env_key(target)] == owner_pid.to_s && alive_fn.call(owner_pid)

        if owner_pid && !alive_fn.call(owner_pid)
          take_over_stale(lock, pid)
          next
        end

        raise Timeout, timeout_message(target, lock, owner_pid, owner_cmd, wait) if now_fn.call >= deadline
        if now_fn.call >= next_notice
          out.puts "[device_lock] #{target} is held by pid #{owner_pid || '?'} (#{owner_cmd}); waiting"
          next_notice = now_fn.call + NOTICE_EVERY
        end
        sleep_fn.call(0.5)
      end
    end
  end

  def release(target, root: dir, pid: Process.pid, env: ENV)
    lock = File.join(root, "#{target}.lock")
    owner_pid, = read_owner(lock)
    return unless owner_pid == pid
    FileUtils.rm_rf(lock)
    env.delete(env_key(target))
  end

  def read_owner(lock)
    pid, cmd = File.read(File.join(lock, "owner")).strip.split(" ", 2)
    [pid.to_i, cmd]
  rescue Errno::ENOENT
    nil
  end

  def take_over_stale(lock, pid)
    grave = "#{lock}.stale.#{pid}"
    File.rename(lock, grave)
    FileUtils.rm_rf(grave)
  rescue Errno::ENOENT
    nil
  end

  def alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  rescue Errno::EPERM
    true
  end

  def timeout_message(target, lock, owner_pid, owner_cmd, wait)
    "#{target} board is still held after #{wait.to_i}s by pid #{owner_pid || '?'} (#{owner_cmd}). " \
    "Wait for it, raise DEVICE_LOCK_WAIT, or if that process is gone for good: rm -r #{lock}"
  end
end
