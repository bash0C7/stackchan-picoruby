require "fileutils"

# Cross-process lock for a USB device, shared with R2P2-dev-harness; a directory per target holds the owner pid.
module DeviceLock
  # Raised when the lock stays held by a live process past the wait limit.
  class Timeout < StandardError; end

  DEFAULT_WAIT = 600
  NOTICE_EVERY = 30

  # @rbs!
  #   interface _Env
  #     def []: (String) -> String?
  #     def []=: (String, String) -> String
  #     def delete: (String) -> String?
  #   end

  module_function

  # Returns the lock directory: R2P2_DEVICE_LOCK_DIR or ~/.cache/r2p2-device-locks.
  #: () -> String
  def dir
    ENV["R2P2_DEVICE_LOCK_DIR"] || File.join(Dir.home, ".cache", "r2p2-device-locks")
  end

  # Returns the environment variable name that records the holder pid of target.
  #: (String target) -> String
  def env_key(target)
    "R2P2_DEVICE_LOCK_HOLDER_#{target.upcase}"
  end

  # Acquires the lock and releases it at process exit. Returns false when this process already holds it.
  #: (String target, ?root: String, ?pid: Integer, ?env: _Env, **untyped opts) -> bool
  def hold(target, root: dir, pid: Process.pid, env: ENV, **opts)
    acquired = acquire(target, root: root, pid: pid, env: env, **opts)
    at_exit { release(target, root: root, pid: pid, env: env) } if acquired
    acquired
  end

  # Acquires the lock, yields, and releases the lock afterwards if this call acquired it. Returns the block value.
  #: [T] (String target, ?root: String, ?pid: Integer, ?env: _Env, **untyped opts) { () -> T } -> T
  def synchronize(target, root: dir, pid: Process.pid, env: ENV, **opts)
    acquired = acquire(target, root: root, pid: pid, env: env, **opts)
    yield
  ensure
    release(target, root: root, pid: pid, env: env) if acquired
  end

  # Takes the lock, waiting up to wait seconds and taking over locks whose owner is dead.
  # Returns true when acquired, false when this process already holds it. Raises Timeout when the wait elapses.
  #: (String target, ?wait: Numeric, ?root: String, ?pid: Integer, ?env: _Env, ?alive_fn: ^(Integer) -> bool, ?sleep_fn: ^(Float) -> void, ?now_fn: ^() -> Time, ?out: IO) -> bool
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

  # Removes the lock when pid owns it and clears the holder environment variable.
  #: (String target, ?root: String, ?pid: Integer, ?env: _Env) -> void
  def release(target, root: dir, pid: Process.pid, env: ENV)
    lock = File.join(root, "#{target}.lock")
    owner_pid, = read_owner(lock)
    return unless owner_pid == pid
    FileUtils.rm_rf(lock)
    env.delete(env_key(target))
  end

  # Returns the owner pid and command recorded in the lock, or nil when the lock has no owner file.
  #: (String lock) -> [Integer, String?]?
  def read_owner(lock)
    pid, cmd = File.read(File.join(lock, "owner")).strip.split(" ", 2)
    [pid.to_i, cmd]
  rescue Errno::ENOENT
    nil
  end

  # Removes a lock whose owner is dead by renaming it aside first.
  #: (String lock, Integer pid) -> void
  def take_over_stale(lock, pid)
    grave = "#{lock}.stale.#{pid}"
    File.rename(lock, grave)
    FileUtils.rm_rf(grave)
  rescue Errno::ENOENT
    nil
  end

  # Returns true when a process with this pid exists.
  #: (Integer pid) -> bool
  def alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  rescue Errno::EPERM
    true
  end

  # Returns the error text for a lock still held after wait seconds.
  #: (String target, String lock, Integer? owner_pid, String? owner_cmd, Numeric wait) -> String
  def timeout_message(target, lock, owner_pid, owner_cmd, wait)
    "#{target} board is still held after #{wait.to_i}s by pid #{owner_pid || '?'} (#{owner_cmd}). " \
    "Wait for it, raise DEVICE_LOCK_WAIT, or if that process is gone for good: rm -r #{lock}"
  end
end
