require "test_helper"
require "stackchan_protocol/led_color_table"

class LedColorTableTest < Test::Unit::TestCase
  def test_red
    assert_equal [255, 0, 0], StackchanProtocol::LED_COLORS.fetch("red")
  end

  def test_green
    assert_equal [0, 255, 0], StackchanProtocol::LED_COLORS.fetch("green")
  end

  def test_blue
    assert_equal [0, 0, 255], StackchanProtocol::LED_COLORS.fetch("blue")
  end

  def test_white
    assert_equal [255, 255, 255], StackchanProtocol::LED_COLORS.fetch("white")
  end

  def test_off_is_zeros
    assert_equal [0, 0, 0], StackchanProtocol::LED_COLORS.fetch("off")
  end

  def test_yellow
    assert_equal [255, 255, 0], StackchanProtocol::LED_COLORS.fetch("yellow")
  end

  def test_cyan
    assert_equal [0, 255, 255], StackchanProtocol::LED_COLORS.fetch("cyan")
  end

  def test_magenta
    assert_equal [255, 0, 255], StackchanProtocol::LED_COLORS.fetch("magenta")
  end

  def test_table_frozen
    assert_predicate StackchanProtocol::LED_COLORS, :frozen?
  end

  def test_unknown_raises_key_error
    assert_raises(KeyError) { StackchanProtocol::LED_COLORS.fetch("puce") }
  end
end

class LedModeTableTest < Test::Unit::TestCase
  def test_solid
    assert_equal "s", StackchanProtocol::LED_MODES.fetch("solid")
  end

  def test_blink
    assert_equal "b", StackchanProtocol::LED_MODES.fetch("blink")
  end

  def test_breathing
    assert_equal "p", StackchanProtocol::LED_MODES.fetch("breathing")
  end

  def test_off
    assert_equal "o", StackchanProtocol::LED_MODES.fetch("off")
  end

  def test_table_frozen
    assert_predicate StackchanProtocol::LED_MODES, :frozen?
  end
end
