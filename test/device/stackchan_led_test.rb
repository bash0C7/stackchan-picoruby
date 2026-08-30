# StackchanLed and StackchanLed::Animator are inlined into app/application.rb
# (extracted from the now-archived picoruby-stackchan-led mrbgem). The picotest
# harness extracts and loads the inlined StackchanLed classes, so they are
# available here as plain host classes. PY32 hardware access is stubbed with FakePy32.
class StackchanLedTest < Picotest::Test
  def setup
    @py32 = FakePy32.new
    @led  = StackchanLed.new(@py32)
  end

  def test_initialize_configures_data_pin_and_count
    names = @py32.calls.map(&:first)
    assert(names.include?(:set_direction))
    assert(names.include?(:set_pull_mode))
    assert(names.include?(:set_drive_mode))
    # set_led_count is called with the 12-pixel ring size.
    count_call = @py32.calls.find { |c| c.first == :set_led_count }
    assert_equal [StackchanLed::PIXEL_COUNT], count_call.last
  end

  def test_fill_range_sets_only_the_given_indices
    @led.fill_range(0, 2, 10, 20, 30)
    @led.show
    px = @py32.last_pixels
    assert_equal [10, 20, 30], px[0]
    assert_equal [10, 20, 30], px[2]
    assert_equal [0, 0, 0],    px[3]
  end

  def test_fill_left_targets_left_half_only
    @led.fill_left(1, 2, 3)
    @led.show
    px = @py32.last_pixels
    assert_equal [1, 2, 3], px[StackchanLed::LEFT_RANGE.first]
    assert_equal [1, 2, 3], px[StackchanLed::LEFT_RANGE.last]
    assert_equal [0, 0, 0], px[StackchanLed::RIGHT_RANGE.first]
  end

  def test_fill_right_targets_right_half_only
    @led.fill_right(4, 5, 6)
    @led.show
    px = @py32.last_pixels
    assert_equal [4, 5, 6], px[StackchanLed::RIGHT_RANGE.first]
    assert_equal [0, 0, 0], px[StackchanLed::LEFT_RANGE.first]
  end

  def test_brightness_scales_pushed_pixels
    @led.fill(100, 200, 50)
    @led.brightness = 50
    @led.show
    # apply_brightness halves each channel via integer division.
    assert_equal [50, 100, 25], @py32.last_pixels[0]
  end

  def test_brightness_clamps_above_100
    @led.brightness = 250
    @led.fill(10, 10, 10)
    @led.show
    # Clamped to 100 → no scaling.
    assert_equal [10, 10, 10], @py32.last_pixels[0]
  end

  def test_brightness_clamps_below_zero
    @led.brightness = -10
    @led.fill(10, 10, 10)
    @led.show
    # Clamped to 0 → all channels zeroed.
    assert_equal [0, 0, 0], @py32.last_pixels[0]
  end

  def test_show_refreshes_via_py32
    @led.show
    names = @py32.calls.map(&:first)
    assert(names.include?(:write_led_ram))
    assert(names.include?(:refresh_leds))
  end

  def test_clear_zeroes_buffer
    @led.fill(255, 255, 255)
    @led.clear
    @led.show
    assert_equal [0, 0, 0], @py32.last_pixels[0]
  end

  def test_animate_side_solid_lights_only_that_half
    @led.animate_side(:left, 7, 8, 9, :solid)
    px = @py32.last_pixels
    assert_equal [7, 8, 9], px[StackchanLed::LEFT_RANGE.first]
    assert_equal [0, 0, 0], px[StackchanLed::RIGHT_RANGE.first]
  end

  def test_animate_side_both_lights_full_ring
    @led.animate_side(:both, 1, 1, 1, :solid)
    px = @py32.last_pixels
    assert_equal [1, 1, 1], px[StackchanLed::LEFT_RANGE.first]
    assert_equal [1, 1, 1], px[StackchanLed::RIGHT_RANGE.first]
  end

  def test_animate_side_off_blanks_the_half
    @led.animate_side(:left, 9, 9, 9, :solid)
    @led.animate_side(:left, 9, 9, 9, :off)
    assert_equal [0, 0, 0], @py32.last_pixels[StackchanLed::LEFT_RANGE.first]
  end

  def test_animate_side_rejects_unknown_side
    assert_raise(ArgumentError) do
      @led.animate_side(:middle, 1, 1, 1, :solid)
    end
  end

  def led_ram_writes
    @py32.calls.select { |c| c.first == :write_led_ram }.size
  end

  def test_animator_tick_skips_i2c_when_the_colour_is_unchanged
    @led.animate_side(:left, 10, 20, 30, :blink)
    @led.tick(0)
    n = led_ram_writes
    @led.tick(20)
    @led.tick(40)
    assert_equal n, led_ram_writes
    @led.tick(500)                      # half period elapsed -> off phase -> one write
    assert_equal n + 1, led_ram_writes
    @led.tick(520)
    assert_equal n + 1, led_ram_writes
  end

  def test_animator_set_always_writes_even_with_the_same_colour
    @led.animate_side(:left, 10, 20, 30, :solid)
    n = led_ram_writes
    @led.animate_side(:left, 10, 20, 30, :solid)
    assert_equal n + 1, led_ram_writes
  end

  def test_animator_restarting_blink_writes_on_the_first_tick_again
    @led.animate_side(:left, 10, 20, 30, :blink)
    @led.tick(0)
    @led.animate_side(:left, 10, 20, 30, :blink)
    n = led_ram_writes
    @led.tick(1000)
    assert_equal n + 1, led_ram_writes
  end
end

class StackchanLedAnimatorTest < Picotest::Test
  def setup
    @py32 = FakePy32.new
    @led  = StackchanLed.new(@py32)
  end

  def animator(range = StackchanLed::LEFT_RANGE)
    StackchanLed::Animator.new(@led, pixel_range: range)
  end

  def test_blink_alternates_on_and_off_each_half_period
    a = animator
    a.set(100, 0, 0, :blink)
    half = StackchanLed::Animator::BLINK_HALF_PERIOD_MS
    # tick origin is the first tick's now_ms; from then elapsed is measured.
    a.tick(0)
    assert_equal [100, 0, 0], @py32.last_pixels[StackchanLed::LEFT_RANGE.first]
    a.tick(half)            # one half-period later → off
    assert_equal [0, 0, 0], @py32.last_pixels[StackchanLed::LEFT_RANGE.first]
    a.tick(half * 2)        # two half-periods → on again
    assert_equal [100, 0, 0], @py32.last_pixels[StackchanLed::LEFT_RANGE.first]
  end

  def test_breathing_scales_color_by_lut_ratio
    a = animator
    a.set(100, 100, 100, :breathing)
    lut  = StackchanLed::Animator::BREATHING_LUT
    step = StackchanLed::Animator::BREATHING_STEP_MS
    a.tick(0)  # establishes phase origin, ratio = lut[0]
    assert_equal [lut[0], lut[0], lut[0]], @py32.last_pixels[StackchanLed::LEFT_RANGE.first]
    a.tick(step)      # ratio = lut[1]
    assert_equal [lut[1], lut[1], lut[1]], @py32.last_pixels[StackchanLed::LEFT_RANGE.first]
    a.tick(step * 6)  # ratio = lut[6] (peak = 100)
    assert_equal [lut[6], lut[6], lut[6]], @py32.last_pixels[StackchanLed::LEFT_RANGE.first]
  end

  def test_breathing_wraps_around_the_lut_period
    a = animator
    a.set(100, 0, 0, :breathing)
    lut  = StackchanLed::Animator::BREATHING_LUT
    step = StackchanLed::Animator::BREATHING_STEP_MS
    a.tick(0)
    # One full LUT period later, the ratio returns to lut[0].
    a.tick(step * lut.size)
    assert_equal [lut[0], 0, 0], @py32.last_pixels[StackchanLed::LEFT_RANGE.first]
  end

  def test_solid_applies_immediately_without_tick
    a = animator
    a.set(5, 6, 7, :solid)
    assert_equal [5, 6, 7], @py32.last_pixels[StackchanLed::LEFT_RANGE.first]
  end

  def test_off_blanks_immediately
    a = animator
    a.set(5, 6, 7, :solid)
    a.set(0, 0, 0, :off)
    assert_equal [0, 0, 0], @py32.last_pixels[StackchanLed::LEFT_RANGE.first]
  end

  def test_tick_is_noop_for_static_modes
    a = animator
    a.set(5, 6, 7, :solid)
    @py32.calls.clear
    a.tick(1000)
    # Static modes don't re-push on tick.
    assert(@py32.calls.empty?)
  end
end
