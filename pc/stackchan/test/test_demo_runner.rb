require_relative "test_helper"
require "stringio"
require "stackchan/demo"

class TestDemoRunner < Test::Unit::TestCase
  class FakeDaemon
    attr_reader :calls
    def initialize; @calls = []; end
    def say(text); @calls << [:say, text]; end
    def face(name); @calls << [:face, name]; end
    def led(side:, color:, mode:); @calls << [:led, side, color, mode]; end
    def servo(**kw); @calls << [:servo, kw]; end
  end

  def test_run_short_duration_emits_intro_and_outro
    daemon = FakeDaemon.new
    stdout = StringIO.new
    Stackchan::Demo::Runner.new(daemon, stdout: stdout).run(duration: 0.1)
    types = daemon.calls.map(&:first)
    assert_equal :say,  daemon.calls.first.first
    assert_equal Stackchan::Demo::INTRO_LINE, daemon.calls.first[1]
    assert_equal :say,  daemon.calls.last.first
    assert_equal Stackchan::Demo::OUTRO_LINE, daemon.calls.last[1]
    assert types.include?(:face)
    assert types.include?(:led)
    assert types.include?(:servo)
  end

  def test_run_resets_to_neutral_before_outro
    daemon = FakeDaemon.new
    Stackchan::Demo::Runner.new(daemon, stdout: StringIO.new).run(duration: 0.1)
    # The last 4 calls should be: face neutral, led off, servo center, say outro
    outro_idx = daemon.calls.size - 1
    assert_equal [:say, Stackchan::Demo::OUTRO_LINE], daemon.calls[outro_idx]
    face_neutral = daemon.calls[outro_idx - 3]
    led_off      = daemon.calls[outro_idx - 2]
    servo_center = daemon.calls[outro_idx - 1]
    assert_equal [:face, "neutral"], face_neutral
    assert_equal [:led, :both, :off, :off], led_off
    assert_equal :servo, servo_center.first
    assert_equal 0, servo_center[1][:yaw_left]
    assert_equal 0, servo_center[1][:pitch_up]
  end
end
