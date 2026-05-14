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

class StackchanLedFillTest < Test::Unit::TestCase
  def test_fill_overwrites_all_pixels
    py32 = FakePY32.new
    led = StackchanLed.new(py32)
    py32.led_ram_calls.clear  # ignore init blank
    led.fill(255, 0, 0).show
    last = py32.led_ram_calls.last
    assert_equal 12, last.size
    last.each { |rgb| assert_equal [255, 0, 0], rgb }
  end

  def test_fill_returns_self_for_chaining
    led = StackchanLed.new(FakePY32.new)
    assert_same led, led.fill(0, 0, 0)
  end
end

class StackchanLedSetRgbTest < Test::Unit::TestCase
  def test_set_rgb_changes_only_one_pixel
    py32 = FakePY32.new
    led = StackchanLed.new(py32)
    led.set_rgb(3, 100, 200, 50).show
    pixels = py32.led_ram_calls.last
    assert_equal [100, 200, 50], pixels[3]
    assert_equal [0, 0, 0], pixels[0]
    assert_equal [0, 0, 0], pixels[11]
  end
end

class StackchanLedClearTest < Test::Unit::TestCase
  def test_clear_resets_all_to_zero
    py32 = FakePY32.new
    led = StackchanLed.new(py32)
    led.fill(255, 255, 255).show
    led.clear.show
    pixels = py32.led_ram_calls.last
    pixels.each { |rgb| assert_equal [0, 0, 0], rgb }
  end
end
