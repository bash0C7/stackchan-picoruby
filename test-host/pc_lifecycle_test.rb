require 'test/unit'
require 'fileutils'
require 'pc_lifecycle'

class PcLifecycleTest < Test::Unit::TestCase
  DIR     = "/tmp/pc_lifecycle_test_#{Process.pid}"
  APP_DIR = "/tmp/pc_lifecycle_test_app_#{Process.pid}"
  LOGDIR  = "/tmp/pc_lifecycle_test_log_#{Process.pid}"
  VM_APP  = File.join(APP_DIR, "App.app")
  VM_BIN  = File.join(VM_APP, "Contents", "MacOS", "picoruby")

  def setup
    @calls = []
    @holder = nil
    @loaded = false
    @ports_ok = true
    @status = { ble_connected: true }
    @bootstrap_result = ["", true]
    # A real (empty) binary at the expected path, so the app-bundle check in
    # `up` is genuinely exercised rather than stubbed out.
    FileUtils.mkdir_p(File.dirname(VM_BIN))
    FileUtils.touch(VM_BIN)
  end

  def teardown
    FileUtils.rm_rf(DIR)
    FileUtils.rm_rf(APP_DIR)
    FileUtils.rm_rf(LOGDIR)
  end

  def config(**over)
    { root: "/repo", vm_app: VM_APP, ruby: "/usr/bin/ruby", port: 8787,
      sidecar_port: 8788, prefix: "StackChan", ble_fake: true, stub: true,
      logdir: LOGDIR, ns: "it" }.merge(over)
  end

  def subject(sleep_fn: nil, clock_fn: nil, **over)
    PcLifecycle.new(
      config(**over), dir: DIR,
      runner: ->(*argv) {
        @calls << argv
        # Only the bootstrap call's exit status matters to `start`; bootout's
        # is discarded, so any other verb can always report success.
        return @bootstrap_result if argv[0..1] == %w[launchctl bootstrap]
        # `launchctl print` here answers "is the job still loaded" for the
        # post-bootout unload wait. Default false ("gone") so every other test's `start`
        # clears the wait on its first check.
        return ["", @loaded] if argv[0..1] == %w[launchctl print]
        ["", true]
      },
      waiter:   ->(_port, _timeout) { @ports_ok },
      releaser: ->(_port, _timeout) { @holder },
      verifier: ->(_port) { @status },
      sleep_fn: sleep_fn,
      clock_fn: clock_fn,
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

  def test_up_always_boots_out_before_bootstrapping
    subject.up
    # `print` is a separate concern (the post-bootout unload wait, covered by
    # its own test below) -- filter it out so this assertion keeps saying
    # only what it means: bootout, then bootstrap, never kickstart.
    assert_equal [["bootout", "com.bash0c7.stackchan-it-sidecar"],
                  ["bootstrap", "com.bash0c7.stackchan-it-sidecar.plist"],
                  ["bootout", "com.bash0c7.stackchan-it-daemon"],
                  ["bootstrap", "com.bash0c7.stackchan-it-daemon.plist"]],
                 launchctl_verbs.reject { |verb, _| verb == "print" }
    assert_false @calls.any? { |a| a[1] == "kickstart" }
  end

  # bootout returns before launchd finishes unloading the service, and
  # bootstrapping while the domain still holds the label fails with
  # "Bootstrap failed: 5: Input/output error" (intermittent). `start` must wait for the label to actually leave the
  # domain before ever writing a plist or bootstrapping.
  def test_up_waits_for_the_job_to_unload_before_bootstrapping
    @loaded = true
    # A fake clock that jumps straight past the deadline on its second read,
    # so the timeout path is proven without spending UNLOAD_WAIT_S of real
    # time (and, since nothing throttles the loop between reads, real CPU)
    # on it. The no-op sleep_fn stays as a safety net in case the loop ever
    # reads the clock more than twice.
    start = Time.now
    reads = [start, start + PcLifecycle::UNLOAD_WAIT_S + 1]
    clock = -> { reads.size > 1 ? reads.shift : reads.first }
    error = assert_raise(PcLifecycle::Error) {
      subject(sleep_fn: ->(_s) {}, clock_fn: clock).up
    }
    assert_match(/was still loaded/, error.message)
    assert_false @calls.any? { |a| a[1] == "bootstrap" }
  end

  # launchd reads a job's definition only at bootstrap; if a second `up` ever
  # took a kickstart path it would restart yesterday's plist, and a stub
  # sidecar would keep answering after the caller asked for the real one.
  def test_a_second_up_installs_the_new_configuration
    subject(stub: true).up
    @calls.clear
    subject(stub: false).up
    plist = File.read(File.join(DIR, "com.bash0c7.stackchan-it-sidecar.plist"))
    assert_not_match(/STACKCHAN_SIDECAR_STUB/, plist)
    assert_equal [["bootout", "com.bash0c7.stackchan-it-sidecar"],
                  ["bootstrap", "com.bash0c7.stackchan-it-sidecar.plist"],
                  ["bootout", "com.bash0c7.stackchan-it-daemon"],
                  ["bootstrap", "com.bash0c7.stackchan-it-daemon.plist"]],
                 launchctl_verbs.reject { |verb, _| verb == "print" }
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

  # A wedged daemon can accept TCP and never answer DRb. This has to fail
  # with a different message than "not connected" -- the operator needs to
  # know the daemon is unresponsive, not merely BLE-less.
  def test_up_fails_when_the_daemon_never_answers_status
    @status = nil
    error = assert_raise(PcLifecycle::Error) { subject.up }
    assert_match(/did not answer status/, error.message)
  end

  # A port still held after our own job has been booted out belongs to a
  # process launchd does not manage. `up` must refuse rather than let the new job die
  # on EADDRINUSE while the port check passes against the squatter.
  def test_up_refuses_when_something_outside_launchd_still_holds_the_port
    @holder = "ruby     38562 bash   10u  IPv4 0x0      0t0  TCP *:8788 (LISTEN)"
    error = assert_raise(PcLifecycle::Error) { subject.up }
    assert_true error.message.include?(@holder)
    # The refusal has to land BEFORE bootstrap. Bootstrapping over a foreign
    # owner is what produced the original defect: the new job dies on
    # EADDRINUSE and the port check then passes against the squatter.
    assert_false @calls.any? { |a| a[1] == "bootstrap" }
  end

  # If `start` wrote the plist before checking the port, a refusal
  # here would leave the definition in ~/Library/LaunchAgents anyway -- and that
  # directory auto-loads at the next login, starting a backend that never
  # came up successfully. The write must not happen until bootstrap is
  # actually going to be attempted.
  def test_up_leaves_no_plist_behind_when_the_port_owner_is_refused
    @holder = "ruby     38562 bash   10u  IPv4 0x0      0t0  TCP *:8788 (LISTEN)"
    assert_raise(PcLifecycle::Error) { subject.up }
    assert_empty Dir[File.join(DIR, "*.plist")]
  end

  def test_up_fails_when_bootstrap_itself_fails
    @bootstrap_result = ["bootstrap refused", false]
    error = assert_raise(PcLifecycle::Error) { subject.up }
    assert_match(/bootstrap refused/, error.message)
  end

  def test_up_creates_the_log_directory
    FileUtils.rm_rf(LOGDIR)
    subject.up
    assert_true Dir.exist?(LOGDIR)
  end

  def test_up_refuses_when_the_app_bundle_binary_is_missing
    File.unlink(VM_BIN)
    error = assert_raise(PcLifecycle::Error) { subject.up }
    assert_match(/pc:app_bundle/, error.message)
  end

  def test_down_boots_out_both_jobs_and_removes_the_plists
    subject.up
    @calls.clear
    subject.down
    assert_equal [["bootout", "com.bash0c7.stackchan-it-sidecar"],
                  ["bootout", "com.bash0c7.stackchan-it-daemon"]], launchctl_verbs
    assert_empty Dir[File.join(DIR, "*.plist")]
  end

  # rake pc:up reaches this file through the Rakefile's require_relative, with
  # no -Ilib on the command line. The suite always runs with -Ilib, so without
  # this check a require that only resolves under -Ilib passes every test here
  # and still crashes both rake tasks.
  def test_the_file_loads_the_way_rake_loads_it_without_ilib
    path = File.expand_path("../lib/pc_lifecycle", __dir__)
    ok = system(RbConfig.ruby, "-e", "require_relative #{path.inspect}",
                out: File::NULL, err: File::NULL)
    assert_true ok, "lib/pc_lifecycle.rb does not load without -Ilib — rake pc:up would raise LoadError"
  end
end
