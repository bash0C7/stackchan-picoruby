require_relative "test_helper"
require "stackchan/display"

class TestDisplay < Test::Unit::TestCase
  # Fake BLE client that records frames produced by SendBuilder, exactly
  # as the real Client#send → send_frame path would emit on the wire.
  class FakeBLE
    attr_reader :frames
    attr_accessor :last_detail_frame

    def initialize
      @frames = []
      @last_detail_frame = nil
    end

    def send(&block)
      builder = Stackchan::BLE::SendBuilder.new
      block.call(builder)
      @frames.concat(builder.to_frames)
      self
    end
  end

  def setup
    @ble = FakeBLE.new
    @ctrl = Stackchan::Display::Controller.new(@ble)
  end

  def test_face_joy_encodes_index_2
    @ctrl.face("joy")
    assert_equal "<F:2>\n", @ble.frames.last
  end

  def test_face_accepts_symbol
    @ctrl.face(:smile)
    assert_equal "<F:1>\n", @ble.frames.last
  end

  def test_face_unknown_raises
    assert_raise(KeyError) { @ctrl.face("bogus") }
  end

  def test_led_left_red_blink
    # :left maps to wire "R" via SIDE_TO_CHAR (StackChan's left hand = wire R).
    @ctrl.led(side: :left, color: :red, mode: :blink)
    assert_equal "<L:1,R:255,G:0,B:0,S:R,M:b>\n", @ble.frames.last
  end

  def test_led_both_green_solid
    @ctrl.led(side: :both, color: :green, mode: :solid)
    assert_equal "<L:1,R:0,G:255,B:0,S:B,M:s>\n", @ble.frames.last
  end

  def test_servo_yaw_left_with_time
    @ctrl.servo(yaw_left: 50, pitch_up: 30, time_ms: 500)
    assert_equal "<YL:50,PU:30,T:500>\n", @ble.frames.last
  end

  def test_servo_returns_last_detail_frame
    @ble.last_detail_frame = "<YL_actual:50,PU_actual:30>\n"
    detail = @ctrl.servo(yaw_left: 50)
    assert_equal "<YL_actual:50,PU_actual:30>\n", detail
  end

  def test_torque_on
    @ctrl.torque(true)
    assert_equal "<torque:on>\n", @ble.frames.last
  end

  def test_torque_off
    @ctrl.torque(false)
    assert_equal "<torque:off>\n", @ble.frames.last
  end

  def test_selftest
    @ctrl.selftest
    assert_equal "<selftest:run>\n", @ble.frames.last
  end
end
