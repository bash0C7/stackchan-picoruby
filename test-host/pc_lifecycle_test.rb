require 'test/unit'
require 'fileutils'
require 'pc_lifecycle'

class PcLifecycleTest < Test::Unit::TestCase
  DIR = "/tmp/pc_lifecycle_test_#{Process.pid}"

  def setup
    @calls = []
    @bootstrapped = []
    @ports_ok = true
    @status = { ble_connected: true }
  end

  def teardown
    FileUtils.rm_rf(DIR)
  end

  def config(**over)
    { root: "/repo", vm_app: "/App.app", ruby: "/usr/bin/ruby", port: 8787,
      sidecar_port: 8788, prefix: "StackChan", ble_fake: true, stub: true,
      logdir: "/tmp/stackchan-pico", ns: "it" }.merge(over)
  end

  def subject(**over)
    PcLifecycle.new(
      config(**over), dir: DIR,
      runner: ->(*argv) {
        @calls << argv
        # `launchctl print` decides bootstrap-vs-kickstart.
        return ["", @bootstrapped.include?(argv.last)] if argv[0..1] == %w[launchctl print]
        ["", true]
      },
      waiter:   ->(_port, _timeout) { @ports_ok },
      verifier: ->(_port) { @status },
    )
  end

  def launchctl_verbs
    @calls.select { |a| a.first == "launchctl" }.map { |a| [a[1], a.last.split("/").last] }
  end

  def test_up_writes_both_plists_from_the_requested_config
    subject.up
    plist = File.read(File.join(DIR, "com.bash0c7.stackchan-it-sidecar.plist"))
    assert_match(/STACKCHAN_SIDECAR_STUB/, plist)
    assert_match(/boot_daemon\.rb/, File.read(File.join(DIR, "com.bash0c7.stackchan-it-daemon.plist")))
  end

  def test_up_bootstraps_a_job_that_is_not_loaded_yet
    subject.up
    assert_equal [["print", "com.bash0c7.stackchan-it-sidecar"],
                  ["bootstrap", "com.bash0c7.stackchan-it-sidecar.plist"],
                  ["print", "com.bash0c7.stackchan-it-daemon"],
                  ["bootstrap", "com.bash0c7.stackchan-it-daemon.plist"]],
                 launchctl_verbs
  end

  # The determinism the whole design rests on: an already-loaded job is never
  # left alone, it is killed and started again (-k).
  def test_up_kickstarts_an_already_loaded_job_so_the_process_is_always_new
    @bootstrapped = ["gui/#{Process.uid}/com.bash0c7.stackchan-it-sidecar",
                     "gui/#{Process.uid}/com.bash0c7.stackchan-it-daemon"]
    subject.up
    assert_equal [["print", "com.bash0c7.stackchan-it-sidecar"],
                  ["kickstart", "com.bash0c7.stackchan-it-sidecar"],
                  ["print", "com.bash0c7.stackchan-it-daemon"],
                  ["kickstart", "com.bash0c7.stackchan-it-daemon"]],
                 launchctl_verbs
    assert_true @calls.any? { |a| a[0..2] == %w[launchctl kickstart -k] }
  end

  def test_up_fails_when_a_port_never_comes_up
    @ports_ok = false
    assert_raise(PcLifecycle::Error) { subject.up }
  end

  # "listening" is not "connected": a daemon that answers DRb but has no link
  # must not be reported as a successful bring-up.
  def test_up_fails_when_the_daemon_is_not_ble_connected
    @status = { ble_connected: false }
    assert_raise(PcLifecycle::Error) { subject.up }
  end

  def test_down_boots_out_both_jobs_and_removes_the_plists
    subject.up
    @calls.clear
    subject.down
    assert_equal [["bootout", "com.bash0c7.stackchan-it-sidecar"],
                  ["bootout", "com.bash0c7.stackchan-it-daemon"]], launchctl_verbs
    assert_empty Dir[File.join(DIR, "*.plist")]
  end
end
