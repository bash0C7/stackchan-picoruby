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

class StackchanLedBrightnessTest < Test::Unit::TestCase
  def test_brightness_default_is_100_no_attenuation
    py32 = FakePY32.new
    led = StackchanLed.new(py32)
    led.fill(100, 200, 50).show
    assert_equal [100, 200, 50], py32.led_ram_calls.last.first
  end

  def test_brightness_50_halves_values
    py32 = FakePY32.new
    led = StackchanLed.new(py32)
    led.brightness = 50
    led.fill(100, 200, 50).show
    assert_equal [50, 100, 25], py32.led_ram_calls.last.first
  end

  def test_brightness_0_blanks
    py32 = FakePY32.new
    led = StackchanLed.new(py32)
    led.brightness = 0
    led.fill(255, 255, 255).show
    assert_equal [0, 0, 0], py32.led_ram_calls.last.first
  end

  def test_brightness_clamps_above_100
    py32 = FakePY32.new
    led = StackchanLed.new(py32)
    led.brightness = 150
    led.fill(100, 0, 0).show
    assert_equal [100, 0, 0], py32.led_ram_calls.last.first
  end

  def test_brightness_clamps_below_0
    py32 = FakePY32.new
    led = StackchanLed.new(py32)
    led.brightness = -50
    led.fill(100, 0, 0).show
    assert_equal [0, 0, 0], py32.led_ram_calls.last.first
  end
end

class StackchanLedAnimateSolidTest < Test::Unit::TestCase
  def setup
    @py32 = FakePY32.new
    @led = StackchanLed.new(@py32)
  end

  def test_animate_solid_pushes_color_immediately
    @led.animate(100, 200, 50, :solid)
    assert_equal [100, 200, 50], @py32.led_ram_calls.last.first
  end

  def test_animate_solid_then_tick_does_not_change
    @led.animate(100, 200, 50, :solid)
    calls_before = @py32.led_ram_calls.size
    @led.tick(123)
    @led.tick(500)
    @led.tick(2000)
    assert_equal calls_before, @py32.led_ram_calls.size, "solid is static; tick is no-op"
  end
end

class StackchanLedAnimateOffTest < Test::Unit::TestCase
  def setup
    @py32 = FakePY32.new
    @led = StackchanLed.new(@py32)
  end

  def test_animate_off_clears_immediately
    @led.fill(255, 255, 255).show
    @led.animate(99, 99, 99, :off)
    assert_equal [0, 0, 0], @py32.led_ram_calls.last.first
  end

  def test_animate_off_tick_no_op
    @led.animate(0, 0, 0, :off)
    calls_before = @py32.led_ram_calls.size
    @led.tick(100)
    assert_equal calls_before, @py32.led_ram_calls.size
  end
end

class AnimatorBlinkTest < Test::Unit::TestCase
  def setup
    @py32 = FakePY32.new
    @led = StackchanLed.new(@py32)
    @py32.led_ram_calls.clear
  end

  def test_blink_first_tick_is_on
    @led.animate(255, 0, 0, :blink)
    @led.tick(0)
    assert_equal [255, 0, 0], @py32.led_ram_calls.last.first
  end

  def test_blink_at_499ms_still_on
    @led.animate(255, 0, 0, :blink)
    @led.tick(0)
    @led.tick(499)
    assert_equal [255, 0, 0], @py32.led_ram_calls.last.first
  end

  def test_blink_at_500ms_off
    @led.animate(255, 0, 0, :blink)
    @led.tick(0)
    @led.tick(500)
    assert_equal [0, 0, 0], @py32.led_ram_calls.last.first
  end

  def test_blink_at_1000ms_on_again
    @led.animate(255, 0, 0, :blink)
    @led.tick(0)
    @led.tick(1000)
    assert_equal [255, 0, 0], @py32.led_ram_calls.last.first
  end

  def test_blink_phase_anchored_to_first_tick
    @led.animate(255, 0, 0, :blink)
    @led.tick(7000)  # first tick sets phase_start_ms = 7000
    @led.tick(7499)  # elapsed 499 -> still on
    assert_equal [255, 0, 0], @py32.led_ram_calls.last.first
    @led.tick(7500)  # elapsed 500 -> off
    assert_equal [0, 0, 0], @py32.led_ram_calls.last.first
  end
end

class AnimatorBreathingTest < Test::Unit::TestCase
  def setup
    @py32 = FakePY32.new
    @led = StackchanLed.new(@py32)
    @py32.led_ram_calls.clear
  end

  def test_breathing_first_tick_step_0_is_zero
    @led.animate(100, 0, 0, :breathing)
    @led.tick(0)
    assert_equal [0, 0, 0], @py32.led_ram_calls.last.first
  end

  def test_breathing_at_250ms_step_1
    # LUT[1] = 5%, 100*5/100 = 5
    @led.animate(100, 0, 0, :breathing)
    @led.tick(0)
    @led.tick(250)
    assert_equal [5, 0, 0], @py32.led_ram_calls.last.first
  end

  def test_breathing_at_1500ms_step_6_peak
    # LUT[6] = 100%, full intensity
    @led.animate(200, 100, 50, :breathing)
    @led.tick(0)
    @led.tick(1500)
    assert_equal [200, 100, 50], @py32.led_ram_calls.last.first
  end

  def test_breathing_wraps_at_3000ms
    # 3000ms / 250 = 12, % 12 = 0, LUT[0] = 0
    @led.animate(100, 0, 0, :breathing)
    @led.tick(0)
    @led.tick(3000)
    assert_equal [0, 0, 0], @py32.led_ram_calls.last.first
  end

  def test_breathing_phase_anchored_to_first_tick
    @led.animate(100, 0, 0, :breathing)
    @led.tick(5000)  # phase_start_ms = 5000
    @led.tick(5250)  # elapsed 250 -> step 1 -> 5
    assert_equal [5, 0, 0], @py32.led_ram_calls.last.first
  end
end
