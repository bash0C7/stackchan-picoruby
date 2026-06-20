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

  def test_run_starts_with_lr_distinct_led_animation
    daemon = FakeDaemon.new
    Stackchan::Demo::Runner.new(daemon, stdout: StringIO.new).run(duration: 0.1)
    # Opening: left red blink + right blue breathing (visible asymmetry).
    assert_equal [:led, :left,  :red,  :blink],     daemon.calls[0]
    assert_equal [:led, :right, :blue, :breathing], daemon.calls[1]
    first_say = daemon.calls.find { |c| c.first == :say }
    assert_equal Stackchan::Demo::INTRO_LINE, first_say[1]
  end

  def test_run_short_duration_ends_with_outro_and_visits_all_axes
    daemon = FakeDaemon.new
    Stackchan::Demo::Runner.new(daemon, stdout: StringIO.new).run(duration: 0.1)
    types = daemon.calls.map(&:first)
    assert_equal [:say, Stackchan::Demo::OUTRO_LINE], daemon.calls.last
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
