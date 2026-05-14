require "test_helper"

class FakePY32HarnessTest < Test::Unit::TestCase
  def test_records_set_led_count
    py32 = FakePY32.new
    py32.set_led_count(12)
    assert_equal [12], py32.led_count_calls
  end

  def test_records_write_led_ram
    py32 = FakePY32.new
    py32.write_led_ram([[1, 2, 3]])
    assert_equal [[[1, 2, 3]]], py32.led_ram_calls
  end

  def test_records_refresh_count
    py32 = FakePY32.new
    py32.refresh_leds
    py32.refresh_leds
    assert_equal 2, py32.refresh_calls
  end
end

class StackchanLedInitializeTest < Test::Unit::TestCase
  def test_sets_led_count_on_init
    py32 = FakePY32.new
    StackchanLed.new(py32)
    assert_equal [12], py32.led_count_calls
  end

  def test_writes_blank_buffer_on_init
    py32 = FakePY32.new
    StackchanLed.new(py32)
    assert_equal 1, py32.led_ram_calls.size
    assert_equal Array.new(12) { [0, 0, 0] }, py32.led_ram_calls.first
  end

  def test_refreshes_after_init_blank
    py32 = FakePY32.new
    StackchanLed.new(py32)
    assert_equal 1, py32.refresh_calls
  end
end
