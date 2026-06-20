require_relative "test_helper"
require "stackchan/ble"

class LedColorTableTest < Test::Unit::TestCase
  def test_red_rgb
    assert_equal [255, 0, 0], Stackchan::BLE::LedColorTable::LED_COLORS.fetch(:red)
  end

  def test_white_rgb
    assert_equal [255, 255, 255], Stackchan::BLE::LedColorTable::LED_COLORS.fetch(:white)
  end

  def test_off_is_black
    assert_equal [0, 0, 0], Stackchan::BLE::LedColorTable::LED_COLORS.fetch(:off)
  end

  def test_keys_are_symbols
    assert_true Stackchan::BLE::LedColorTable::LED_COLORS.keys.all? { |k| k.is_a?(Symbol) }
  end

  def test_unknown_color_raises_key_error
    assert_raise(KeyError) do
      Stackchan::BLE::LedColorTable::LED_COLORS.fetch(:bogus)
    end
  end
end
