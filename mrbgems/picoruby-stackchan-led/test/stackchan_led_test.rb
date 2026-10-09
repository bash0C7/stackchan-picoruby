class StackchanLedTest < Picotest::Test
  def setup
    @py32 = FakePy32.new
    @led  = StackchanLed.new(@py32)
  end

  def test_initialize_configures_the_data_pin_and_sets_the_count_to_the_12_pixel_ring
    names = @py32.calls.map(&:first)
    assert(names.include?(:set_direction))
    assert(names.include?(:set_pull_mode))
    assert(names.include?(:set_drive_mode))
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

  def test_show_refreshes_via_py32
    @led.show
    names = @py32.calls.map(&:first)
    assert(names.include?(:write_led_ram))
    assert(names.include?(:refresh_leds))
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
    @led.tick(500)
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

  def test_flash_side_holds_the_colour_until_the_deadline_then_blanks_that_half_only
    @led.animate_side(:right, 4, 5, 6, :solid)
    t = Machine.uptime_us / 1000
    @led.flash_side(:left, 1, 2, 3)
    @led.tick(t + 299)
    assert_equal [1, 2, 3], @py32.last_pixels[StackchanLed::LEFT_RANGE.first]
    @led.tick(t + 300)
    assert_equal [0, 0, 0], @py32.last_pixels[StackchanLed::LEFT_RANGE.first]
    assert_equal [4, 5, 6], @py32.last_pixels[StackchanLed::RIGHT_RANGE.first]
  end

  def test_animate_side_after_a_flash_is_not_blanked_by_the_flash_deadline
    t = Machine.uptime_us / 1000
    @led.flash_side(:both, 0, 255, 0)
    @led.animate_side(:both, 255, 0, 0, :blink)
    @led.tick(t + 300)
    assert_equal [255, 0, 0], @py32.last_pixels[StackchanLed::LEFT_RANGE.first]
    assert_equal [255, 0, 0], @py32.last_pixels[StackchanLed::RIGHT_RANGE.first]
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

  def test_blink_alternates_on_and_off_each_half_period_from_the_first_tick
    a = animator
    a.set(100, 0, 0, :blink)
    half = StackchanLed::Animator::BLINK_HALF_PERIOD_MS
    a.tick(0)
    assert_equal [100, 0, 0], @py32.last_pixels[StackchanLed::LEFT_RANGE.first]
    a.tick(half)
    assert_equal [0, 0, 0], @py32.last_pixels[StackchanLed::LEFT_RANGE.first]
    a.tick(half * 2)
    assert_equal [100, 0, 0], @py32.last_pixels[StackchanLed::LEFT_RANGE.first]
  end

  def test_breathing_scales_color_by_lut_ratio
    a = animator
    a.set(100, 100, 100, :breathing)
    lut  = StackchanLed::Animator::BREATHING_LUT
    step = StackchanLed::Animator::BREATHING_STEP_MS
    a.tick(0)
    assert_equal [lut[0], lut[0], lut[0]], @py32.last_pixels[StackchanLed::LEFT_RANGE.first]
    a.tick(step)
    assert_equal [lut[1], lut[1], lut[1]], @py32.last_pixels[StackchanLed::LEFT_RANGE.first]
    a.tick(step * 6)
    assert_equal [lut[6], lut[6], lut[6]], @py32.last_pixels[StackchanLed::LEFT_RANGE.first]
  end

  def test_breathing_returns_to_the_first_ratio_one_lut_period_later
    a = animator
    a.set(100, 0, 0, :breathing)
    lut  = StackchanLed::Animator::BREATHING_LUT
    step = StackchanLed::Animator::BREATHING_STEP_MS
    a.tick(0)
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

  def test_tick_does_not_write_for_static_modes
    a = animator
    a.set(5, 6, 7, :solid)
    @py32.calls.clear
    a.tick(1000)
    assert(@py32.calls.empty?)
  end
end
