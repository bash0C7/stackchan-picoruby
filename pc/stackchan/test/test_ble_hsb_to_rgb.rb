require_relative "test_helper"
require "stackchan/ble"

class HsbToRgbTest < Test::Unit::TestCase
  # H byte semantics: 0-255 maps linearly to 0-360°.
  # S/B bytes: 0-255 map linearly to 0-100%.

  def test_zero_brightness_is_black
    assert_equal [0, 0, 0], Stackchan::BLE::HsbToRgb.convert(0x000000)
    assert_equal [0, 0, 0], Stackchan::BLE::HsbToRgb.convert(0xFFFF00)
  end

  def test_zero_saturation_is_grayscale_at_brightness
    # full brightness, no saturation → white
    assert_equal [255, 255, 255], Stackchan::BLE::HsbToRgb.convert(0xAA00FF)
    # half brightness, no saturation → mid-gray
    r, g, b = Stackchan::BLE::HsbToRgb.convert(0xAA0080)
    assert_equal r, g
    assert_equal g, b
    assert_in_delta 128, r, 2
  end

  def test_pure_red_full_sat_full_bright
    # H=0 (red), S=255, B=255
    assert_equal [255, 0, 0], Stackchan::BLE::HsbToRgb.convert(0x00FFFF)
  end

  def test_pure_green_full_sat_full_bright
    # H ≈ 120° → 120/360*256 ≈ 85
    r, g, b = Stackchan::BLE::HsbToRgb.convert(0x55FFFF)
    assert_in_delta 0,   r, 6
    assert_in_delta 255, g, 6
    assert_in_delta 0,   b, 6
  end

  def test_pure_blue_full_sat_full_bright
    # H ≈ 240° → 240/360*256 ≈ 170
    r, g, b = Stackchan::BLE::HsbToRgb.convert(0xAAFFFF)
    assert_in_delta 0,   r, 6
    assert_in_delta 0,   g, 6
    assert_in_delta 255, b, 6
  end

  def test_pure_yellow_full_sat_full_bright
    # H ≈ 60° → 60/360*256 ≈ 43
    r, g, b = Stackchan::BLE::HsbToRgb.convert(0x2BFFFF)
    assert_in_delta 255, r, 6
    assert_in_delta 255, g, 6
    assert_in_delta 0,   b, 6
  end

  def test_returns_three_integers_in_0_255
    [0x00FFFF, 0x55FFFF, 0xAAFFFF, 0xFFFFFF, 0x80808080 & 0xFFFFFF, 0x12345678 & 0xFFFFFF].each do |packed|
      r, g, b = Stackchan::BLE::HsbToRgb.convert(packed)
      [r, g, b].each do |v|
        assert_kind_of Integer, v
        assert_operator v, :>=, 0
        assert_operator v, :<=, 255
      end
    end
  end
end
