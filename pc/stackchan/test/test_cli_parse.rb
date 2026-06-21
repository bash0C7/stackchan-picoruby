require_relative "test_helper"
require "stackchan/cli"

class TestCLIVerbList < Test::Unit::TestCase
  def test_verbs_include_core_set
    %w[connect status stop say chat face led servo torque selftest touch raw calibrate tui].each do |v|
      assert_include Stackchan::CLI::VERBS, v
    end
  end

  def test_repl_verb_was_removed
    assert_false Stackchan::CLI::VERBS.include?("repl")
  end

  def test_status_is_observe_only
    assert_include Stackchan::CLI::OBSERVE_ONLY_VERBS, "status"
    assert_false Stackchan::CLI::OBSERVE_ONLY_VERBS.include?("connect")
    assert_false Stackchan::CLI::OBSERVE_ONLY_VERBS.include?("face")
  end
end

class TestCLIDispatch < Test::Unit::TestCase
  # FakeDaemon records verb calls; CLI.new(daemon) dispatches into this.
  class FakeDaemon
    attr_reader :calls
    def initialize; @calls = []; end
    def face(name); @calls << [:face, name]; end
    def led(side:, color:, mode:); @calls << [:led, side, color, mode]; end
    def servo(**kw); @calls << [:servo, kw]; end
    def torque(on); @calls << [:torque, on]; end
    def selftest; @calls << [:selftest]; end
    def say(text, voice: nil, gain: nil, rate: nil); @calls << [:say, text, voice, gain, rate]; end
    def chat(text, speak: true); @calls << [:chat, text, speak]; "ok" end
    def raw_send(frame); @calls << [:raw, frame]; end
    def status; { ble_connected: true }; end
  end

  def setup
    @daemon = FakeDaemon.new
    @cli = Stackchan::CLI.new(@daemon)
  end

  def test_face_dispatches_name
    @cli.dispatch("face", ["joy"])
    assert_equal [:face, "joy"], @daemon.calls.last
  end

  def test_led_dispatches_side_color_mode_as_symbols
    @cli.dispatch("led", ["left", "red", "blink"])
    assert_equal [:led, :left, :red, :blink], @daemon.calls.last
  end

  def test_servo_parses_kw_options
    @cli.dispatch("servo", ["--yaw-left", "50", "--pitch-up", "30", "--time", "500"])
    assert_equal [:servo, { yaw_left: 50, yaw_right: nil, pitch_up: 30, time_ms: 500, velocity: nil }], @daemon.calls.last
  end

  def test_torque_on
    @cli.dispatch("torque", ["on"])
    assert_equal [:torque, true], @daemon.calls.last
  end

  def test_torque_off_for_unknown_value
    @cli.dispatch("torque", ["off"])
    assert_equal [:torque, false], @daemon.calls.last
  end

  def test_say_parses_text_and_gain
    @cli.dispatch("say", ["こんにちは", "--gain", "0.2"])
    assert_equal [:say, "こんにちは", nil, 0.2, nil], @daemon.calls.last
  end

  def test_chat_default_speaks
    @cli.dispatch("chat", ["text"])
    assert_equal [:chat, "text", true], @daemon.calls.last
  end

  def test_chat_no_speak_flag
    @cli.dispatch("chat", ["text", "--no-speak"])
    assert_equal [:chat, "text", false], @daemon.calls.last
  end

  def test_raw_joins_args
    @cli.dispatch("raw", ["<F:1>"])
    assert_equal [:raw, "<F:1>"], @daemon.calls.last
  end
end
