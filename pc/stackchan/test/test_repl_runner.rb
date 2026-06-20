require_relative "test_helper"
require "stringio"
require "stackchan/cli"
require "stackchan/repl"

class TestREPLRunner < Test::Unit::TestCase
  class FakeCli
    attr_reader :calls
    def initialize; @calls = []; end
    def dispatch(verb, args); @calls << [verb, args]; 0; end
  end

  class FakeDaemon
    attr_accessor :touch_events
    def initialize; @touch_events = []; end
    def subscribe_touch
      @touch_events.each { |e| yield e }
      # then block forever until killed, simulating daemon's infinite channel.each
      sleep
    end
  end

  def run_with(script, touch_events: [])
    cli = FakeCli.new
    daemon = FakeDaemon.new
    daemon.touch_events = touch_events
    stdin = StringIO.new(script)
    stdout = StringIO.new
    Stackchan::REPL::Runner.new(cli, daemon, stdin: stdin, stdout: stdout).run
    [cli.calls, stdout.string]
  end

  def test_quit_exits_cleanly
    calls, out = run_with("q\n")
    assert_empty calls
    assert out.include?("Type any stackchan verb")
  end

  def test_help_prints_help
    _, out = run_with("h\nq\n")
    assert out.scan(/Type any stackchan verb/).size >= 2
  end

  def test_face_dispatches_to_cli
    calls, _ = run_with("face joy\nq\n")
    assert_equal ["face", ["joy"]], calls.first
  end

  def test_say_with_quoted_text_parses_via_shellwords
    calls, _ = run_with(%(say "おはよう こんにちは" --gain 0.1\nq\n))
    assert_equal ["say", ["おはよう こんにちは", "--gain", "0.1"]], calls.first
  end

  def test_servo_passes_kw_args
    calls, _ = run_with("servo --yaw-left 50 --time 500\nq\n")
    assert_equal ["servo", ["--yaw-left", "50", "--time", "500"]], calls.first
  end

  def test_disallowed_verbs_are_blocked
    calls, out = run_with("repl\ntui\nstop\ntouch listen\nq\n")
    assert_empty calls
    assert out.include?("'repl' is not available")
    assert out.include?("'tui' is not available")
    assert out.include?("'stop' is not available")
    assert out.include?("'touch' is not available")
  end

  def test_unknown_verb_reports
    calls, out = run_with("doesnotexist\nq\n")
    assert_empty calls
    assert out.include?("unknown verb: doesnotexist")
  end

  def test_empty_line_skipped
    calls, _ = run_with("\n\nface joy\nq\n")
    assert_equal 1, calls.size
  end

  def test_touch_events_render_inline
    _, out = run_with("q\n", touch_events: [{ type: :touch, zone: 2 }, { type: :touch, zone: 1 }])
    # Touch listener runs in background; give it a moment to flush
    sleep 0.1
    assert out.include?("[touch] zone=")
  end
end
