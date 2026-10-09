require 'test/unit'
require 'tmpdir'
require 'stringio'
require 'device_lock'

class DeviceLockTest < Test::Unit::TestCase
  def setup
    @root = Dir.mktmpdir
    @env = {}
    @out = StringIO.new
    @t = 0.0
  end

  def teardown
    FileUtils.rm_rf(@root)
  end

  def acquire(target = "esp32", pid: 100, alive: ->(_) { true }, wait: 5, env: @env)
    DeviceLock.acquire(target, wait: wait, root: @root, pid: pid, env: env, alive_fn: alive,
                       sleep_fn: ->(s) { @t += s }, now_fn: -> { Time.at(@t) }, out: @out)
  end

  def test_acquire_then_release_frees_the_board
    assert_true acquire
    assert_equal "100", @env[DeviceLock.env_key("esp32")]
    DeviceLock.release("esp32", root: @root, pid: 100, env: @env)
    assert_false File.exist?(File.join(@root, "esp32.lock"))
    assert_true acquire(pid: 200, env: {})
  end

  def test_the_lock_is_the_one_r2p2_dev_harness_takes_for_every_esp32
    assert_equal File.join(Dir.home, ".cache", "r2p2-device-locks"), DeviceLock.dir unless ENV["R2P2_DEVICE_LOCK_DIR"]
    acquire
    assert_equal "100", File.read(File.join(@root, "esp32.lock", "owner")).split.first
  end

  def test_second_process_waits_then_times_out_naming_the_holder
    acquire(pid: 100)
    err = assert_raise(DeviceLock::Timeout) { acquire(pid: 200, env: {}, wait: 2) }
    assert_include err.message, "pid 100"
    assert_include @out.string, "held by pid 100"
  end

  def test_child_of_the_holder_passes_without_owning
    acquire(pid: 100)
    assert_false acquire(pid: 200, env: @env)
    DeviceLock.release("esp32", root: @root, pid: 200, env: @env)
    assert_true File.exist?(File.join(@root, "esp32.lock"))
  end

  def test_dead_holder_is_taken_over
    acquire(pid: 100)
    assert_true acquire(pid: 200, env: {}, alive: ->(pid) { pid != 100 })
    assert_equal "200", File.read(File.join(@root, "esp32.lock", "owner")).split.first
  end

  def test_synchronize_releases_even_when_the_block_raises
    assert_raise(RuntimeError) do
      DeviceLock.synchronize("esp32", root: @root, pid: 100, env: @env, out: @out) { raise "boom" }
    end
    assert_false File.exist?(File.join(@root, "esp32.lock"))
  end

  def test_synchronize_holds_during_the_block
    DeviceLock.synchronize("esp32", root: @root, pid: 100, env: @env, out: @out) do
      assert_raise(DeviceLock::Timeout) { acquire("esp32", pid: 200, env: {}, wait: 1) }
    end
  end

  def test_release_by_non_owner_keeps_the_lock
    acquire(pid: 100)
    DeviceLock.release("esp32", root: @root, pid: 999, env: {})
    assert_true File.exist?(File.join(@root, "esp32.lock"))
  end
end
