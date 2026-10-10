class CliDispatchTest < Picotest::Test
  class ScriptedDaemon
    attr_reader :calls

    def initialize(results: {}, touches: [], remote_results: {}, remote_result: nil)
      @calls = []
      @results = results
      @touches = touches
      @remote_results = remote_results
      @remote_result = remote_result
    end

    def act(name, args)
      @calls << [:act, name.to_s, args]
      @results.fetch(name.to_s) { { status: :unknown, out: nil, message: "unknown action: #{name}" } }
    end

    def actions
      @calls << [:actions]
      [[:connect, nil], [:status, nil], [:stop, nil], [:face, "Face"], [:led, nil]]
    end

    def poll_touch
      @calls << [:poll_touch]
      @touches.shift
    end

    def remote(msg, args = [])
      @calls << [:remote, msg.to_s, args]
      return @remote_result if @remote_result
      { status: :ok, out: @remote_results.fetch(msg.to_s) { [] }, message: nil }
    end
  end

  class ScriptedCLI < StackChan::Controller::CLI
    attr_reader :lines

    def initialize(daemon, input: [])
      super(daemon)
      @lines = []
      @input = input
    end

    private

    def out(s)
      @lines << s
    end

    def read_line(_prompt)
      @input.shift
    end
  end

  def ok(out)
    { status: :ok, out: out, message: nil }
  end

  def setup
    FakeClock.reset(0)
  end

  def test_a_declared_verb_is_one_act_with_its_argv
    daemon = ScriptedDaemon.new(results: { "face" => ok("OK face=joy") })
    cli = ScriptedCLI.new(daemon)
    assert_equal 0, cli.dispatch("face", ["joy"])
    assert_equal [[:act, "face", ["joy"]]], daemon.calls
    assert_equal ["OK face=joy"], cli.lines
  end

  def test_an_unknown_verb_prints_the_built_ins_then_the_actions_and_exits_1
    daemon = ScriptedDaemon.new
    cli = ScriptedCLI.new(daemon)
    assert_equal 1, cli.dispatch("nope", [])
    assert_equal [[:act, "nope", []], [:actions]], daemon.calls
    assert_equal ["Usage: stackchan <verb> [args]",
                  "Verbs: connect, status, stop, raw, calibrate, remote, touch, tui, face, led"], cli.lines
  end

  def test_busy_prints_busy_and_exits_8
    daemon = ScriptedDaemon.new(results: { "face" => { status: :busy, out: nil, message: "robot is held" } })
    cli = ScriptedCLI.new(daemon)
    assert_equal 8, cli.dispatch("face", ["joy"])
    assert_equal ["busy: robot is held"], cli.lines
  end

  def test_an_error_prints_error_and_exits_1
    daemon = ScriptedDaemon.new(results: { "face" => { status: :error, out: nil, message: "boom" } })
    cli = ScriptedCLI.new(daemon)
    assert_equal 1, cli.dispatch("face", ["joy"])
    assert_equal ["error: boom"], cli.lines
  end

  def test_an_array_prints_one_line_per_element
    daemon = ScriptedDaemon.new(results: { "demo" => ok(["[demo] start", "[demo] done\n"]) })
    cli = ScriptedCLI.new(daemon)
    assert_equal 0, cli.dispatch("demo", [])
    assert_equal ["[demo] start", "[demo] done"], cli.lines
  end

  def test_status_prints_one_key_value_line
    status = { link: "held", connects: 1, releases: 0, ble_connected: true, hold_ms: 10_000, last_face: "joy" }
    daemon = ScriptedDaemon.new(results: { "status" => ok(status) })
    cli = ScriptedCLI.new(daemon)
    assert_equal 0, cli.dispatch("status", [])
    assert_equal ["link=held connects=1 releases=0 ble_connected=true hold_ms=10000 last_face=joy"], cli.lines
  end

  def test_touch_listen_with_a_count_exits_0_after_that_many_events
    daemon = ScriptedDaemon.new(results: { "connect" => ok("Connected; RX value_handle bound") },
                                touches: [nil, { zone: 0, name: :back }])
    cli = ScriptedCLI.new(daemon)
    assert_equal 0, cli.dispatch("touch", ["listen", "--count", "1", "--timeout", "2"])
    assert_equal [:act, "connect", []], daemon.calls[0]
    assert_equal ["[touch] listening (Ctrl-C to exit)...", "touch zone=0 (back)"], cli.lines
    assert_equal [200], FakeClock.sleeps
  end

  def test_touch_listen_exits_1_on_timeout
    daemon = ScriptedDaemon.new(results: { "connect" => ok("Connected; RX value_handle bound") })
    cli = ScriptedCLI.new(daemon)
    assert_equal 1, cli.dispatch("touch", ["listen", "--count", "1", "--timeout", "2"])
    assert_equal 2000, FakeClock.now
    assert_equal "[touch] timed out", cli.lines.last
  end

  def test_touch_listen_exits_1_when_the_link_is_released
    daemon = ScriptedDaemon.new(results: { "connect" => ok("Connected; RX value_handle bound") },
                                touches: [{ released: true }, { zone: 1, name: :right }])
    cli = ScriptedCLI.new(daemon)
    assert_equal 1, cli.dispatch("touch", ["listen"])
    assert_equal "[touch] released", cli.lines.last
    assert_equal 1, daemon.calls.select { |c| c[0] == :poll_touch }.size
  end

  def test_touch_listen_on_a_busy_robot_exits_8_without_polling
    daemon = ScriptedDaemon.new(results: { "connect" => { status: :busy, out: nil, message: "robot is held" } })
    cli = ScriptedCLI.new(daemon)
    assert_equal 8, cli.dispatch("touch", ["listen", "--count", "1"])
    assert_equal [[:act, "connect", []]], daemon.calls
    assert_equal ["busy: robot is held"], cli.lines
  end

  def test_remote_with_an_array_of_integers_prints_each_and_exits_0
    daemon = ScriptedDaemon.new(remote_results: { "touches" => [1, 2] })
    cli = ScriptedCLI.new(daemon)
    assert_equal 0, cli.dispatch("remote", ["touches"])
    assert_equal ["1", "2"], cli.lines
  end

  def test_remote_with_a_boolean_prints_it_and_exits_0
    daemon = ScriptedDaemon.new(remote_results: { "audio_done" => false })
    cli = ScriptedCLI.new(daemon)
    assert_equal 0, cli.dispatch("remote", ["audio_done"])
    assert_equal ["false"], cli.lines
  end

  def test_remote_whose_first_line_is_a_rejection_exits_1
    daemon = ScriptedDaemon.new(remote_results: { "command" => ["?\n"] })
    cli = ScriptedCLI.new(daemon)
    assert_equal 1, cli.dispatch("remote", ["command", "F=9"])
    assert_equal ["?"], cli.lines
  end

  def test_remote_busy_exits_8
    daemon = ScriptedDaemon.new(remote_result: { status: :busy, out: nil, message: "robot is held" })
    cli = ScriptedCLI.new(daemon)
    assert_equal 8, cli.dispatch("remote", ["command", "F=2"])
    assert_equal ["busy: robot is held"], cli.lines
  end

  def test_remote_that_failed_in_the_daemon_prints_the_error_and_exits_1
    daemon = ScriptedDaemon.new(remote_result: { status: :error, out: nil, message: "drbble: no reply in 3000 ms" })
    cli = ScriptedCLI.new(daemon)
    assert_equal 1, cli.dispatch("remote", ["servo", "YL=40"])
    assert_equal ["error: drbble: no reply in 3000 ms"], cli.lines
  end

  def test_tui_runs_each_line_as_an_action_until_quit
    daemon = ScriptedDaemon.new(results: { "face" => ok("OK face=joy"), "led" => { status: :busy, out: nil, message: "held" } })
    cli = ScriptedCLI.new(daemon, input: ["face joy\n", "\n", "led both red solid\n", "q\n", "face sad\n"])
    assert_equal 0, cli.dispatch("tui", [])
    assert_equal [[:act, "face", ["joy"]], [:act, "led", ["both", "red", "solid"]]], daemon.calls
    assert_equal ["OK face=joy", "busy: held"], cli.lines.reject { |l| l.start_with?("commands:") }
  end
end
