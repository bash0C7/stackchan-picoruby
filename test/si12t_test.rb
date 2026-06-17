$LOAD_PATH.unshift(File.expand_path('.', __dir__))
require 'test_helper'
require 'fake_i2c'

# Si12T is inlined in app/application.rb; test_helper extracts it via prism AST.
class Si12TTest < Test::Unit::TestCase
  def setup
    @i2c = FakeI2C.new
    @si  = Si12T.new(@i2c)
  end

  def test_init_writes_enable_ctrl_and_sensitivity_registers
    w = @i2c.writes
    (0x0A..0x0F).each { |reg| assert_includes w, [Si12T::ADDR, [reg, 0x00]] }
    ctrl2 = w.select { |a, d| a == Si12T::ADDR && d[0] == 0x09 }.map { |_a, d| d[1] }
    assert_equal [0x0F, 0x07], ctrl2, "Ctrl2 (0x09) must be written 0x0F then 0x07 in order"
    assert_includes w, [Si12T::ADDR, [0x08, 0x22]]
    (0x02..0x06).each { |reg| assert_includes w, [Si12T::ADDR, [reg, 0x33]] }
  end

  def test_read_zones_unpacks_two_bits_per_zone
    @i2c.script_reads(0b00111001)
    assert_equal [1, 2, 3], @si.read_zones
  end

  def test_read_zones_returns_zeros_on_failed_read
    @i2c.script_reads(nil)
    assert_equal [0, 0, 0], @si.read_zones
  end

  def test_poll_fires_once_on_rising_edge_then_nil_while_held_and_released
    @i2c.script_reads(0b000001, 0b000001, 0b000000)
    assert_equal 0, @si.poll
    assert_nil   @si.poll
    assert_nil   @si.poll
  end

  def test_poll_refires_after_release
    @i2c.script_reads(0b000100, 0b000000, 0b000100)
    assert_equal 1, @si.poll
    assert_nil   @si.poll
    assert_equal 1, @si.poll
  end

  def test_poll_returns_highest_intensity_zone_lowest_index_on_tie
    @i2c.script_reads(0b001010)
    assert_equal 0, @si.poll
  end
end
