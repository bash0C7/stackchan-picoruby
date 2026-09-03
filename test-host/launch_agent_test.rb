require 'test/unit'
require 'needs_plutil'
require 'fileutils'
require 'launch_agent'

class LaunchAgentTest < Test::Unit::TestCase
  include NeedsPlutil

  ROOT   = "/repo"
  VM_APP = "/Users/x/Applications/StackchanPico.app"
  LOGDIR = "/tmp/stackchan-pico"

  def daemon(**over)
    LaunchAgent.daemon_job(root: ROOT, vm_app: VM_APP, port: 8787, prefix: "StackChan",
                           ble_fake: false, logdir: LOGDIR, **over)
  end

  def sidecar(**over)
    LaunchAgent.sidecar_job(root: ROOT, ruby: "/usr/bin/ruby", port: 8788,
                            stub: false, logdir: LOGDIR, **over)
  end

  def test_daemon_job_runs_the_bundle_binary_with_the_boot_script
    job = daemon
    assert_equal "com.bash0c7.stackchan-daemon", job["Label"]
    assert_equal ["#{VM_APP}/Contents/MacOS/picoruby",
                  "#{ROOT}/pc/stackchan-pico/app/boot_daemon.rb",
                  ROOT, "8787", "StackChan"], job["ProgramArguments"]
    assert_equal "#{LOGDIR}/daemon.log", job["StandardOutPath"]
    assert_equal "#{LOGDIR}/daemon.log", job["StandardErrorPath"]
  end

  def test_fake_ble_daemon_passes_fake_instead_of_a_prefix
    job = daemon(ble_fake: true)
    assert_equal [ROOT, "8787", "fake"], job["ProgramArguments"][2..]
  end

  # Supervision: restart on abnormal exit only. A daemon that exits 0 because
  # the robot is off must not respawn in a loop.
  def test_jobs_run_at_load_and_restart_only_on_failure
    [daemon, sidecar].each do |job|
      assert_equal true, job["RunAtLoad"]
      assert_equal({ "SuccessfulExit" => false }, job["KeepAlive"])
    end
  end

  def test_sidecar_job_carries_the_bundler_environment
    env = sidecar["EnvironmentVariables"]
    assert_equal "#{ROOT}/pc/stackchan/Gemfile", env["BUNDLE_GEMFILE"]
    assert_equal "-rbundler/setup", env["RUBYOPT"]
    assert_equal ["/usr/bin/ruby", "#{ROOT}/pc/sidecar/sidecar.rb", "8788"],
                 sidecar["ProgramArguments"]
  end

  # The 8-day muted-say regression: an ambient STACKCHAN_SIDECAR_STUB must not
  # be able to reach the job. The key exists only when stub was asked for.
  def test_stub_flag_is_present_only_when_requested
    assert_equal "1", sidecar(stub: true)["EnvironmentVariables"]["STACKCHAN_SIDECAR_STUB"]
    assert_false sidecar(stub: false)["EnvironmentVariables"].key?("STACKCHAN_SIDECAR_STUB")
    ENV["STACKCHAN_SIDECAR_STUB"] = "1"
    assert_false sidecar(stub: false)["EnvironmentVariables"].key?("STACKCHAN_SIDECAR_STUB")
  ensure
    ENV.delete("STACKCHAN_SIDECAR_STUB")
  end

  def test_namespace_separates_labels_so_tests_cannot_touch_the_real_jobs
    assert_equal "com.bash0c7.stackchan-it-daemon",  LaunchAgent.daemon_label("it")
    assert_equal "com.bash0c7.stackchan-it-sidecar", LaunchAgent.sidecar_label("it")
  end

  def test_write_produces_a_plist_that_plutil_accepts
    dir = "/tmp/launch_agent_test_#{Process.pid}"
    needs_plutil
    path = LaunchAgent.write(daemon(ns: "it"), dir: dir)
    assert_equal File.join(dir, "com.bash0c7.stackchan-it-daemon.plist"), path
    assert system("plutil", "-lint", path, out: File::NULL)
    assert_match(/boot_daemon\.rb/, File.read(path))
    assert_false File.exist?("#{path}.json")
  ensure
    FileUtils.rm_rf(dir)
  end
end
