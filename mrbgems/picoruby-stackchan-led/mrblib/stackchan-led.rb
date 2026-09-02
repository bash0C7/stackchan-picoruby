# 12-pixel WS2812 ring via PY32IOExpander; each half has an Animator.
class StackchanLed
  PIXEL_COUNT  = 12
  LED_DATA_PIN = 13

  LEFT_RANGE  = (0..5)
  RIGHT_RANGE = (6..11)

  class Animator
    BLINK_HALF_PERIOD_MS = 500
    BREATHING_LUT = [0, 5, 20, 45, 70, 90, 100, 90, 70, 45, 20, 5].freeze
    BREATHING_STEP_MS = 250

    def initialize(led, pixel_range:)
      @led = led
      @pixel_range = pixel_range
      @r = 0
      @g = 0
      @b = 0
      @mode = :off
      @phase_start_ms = nil
    end

    def set(r, g, b, mode)
      @r = r
      @g = g
      @b = b
      @mode = mode
      @phase_start_ms = nil
      @last_applied = nil
      apply_immediately
    end

    # apply_color is three I2C transactions on the bus the touch sensor shares,
    # so write only when the colour changes.
    def tick(now_ms)
      return unless dynamic?
      @phase_start_ms ||= now_ms
      elapsed = now_ms - @phase_start_ms
      case @mode
      when :blink
        on = (elapsed / BLINK_HALF_PERIOD_MS) % 2 == 0
        apply_color_if_changed(on ? @r : 0, on ? @g : 0, on ? @b : 0)
      when :breathing
        ratio = BREATHING_LUT[(elapsed / BREATHING_STEP_MS) % BREATHING_LUT.size]
        apply_color_if_changed(@r * ratio / 100, @g * ratio / 100, @b * ratio / 100)
      end
    end

    private

    def dynamic?
      @mode == :blink || @mode == :breathing
    end

    def apply_immediately
      case @mode
      when :solid then apply_color(@r, @g, @b)
      when :off   then apply_color(0, 0, 0)
      end
    end

    def apply_color(r, g, b)
      @led.fill_range(@pixel_range.first, @pixel_range.last, r, g, b)
      @led.show
    end

    def apply_color_if_changed(r, g, b)
      rgb = [r, g, b]
      return if @last_applied == rgb
      @last_applied = rgb
      apply_color(r, g, b)
    end
  end

  def initialize(py32)
    @py32 = py32
    @brightness = 100
    @buffer = Array.new(PIXEL_COUNT) { [0, 0, 0] }
    @py32.set_direction(LED_DATA_PIN, true)
    @py32.set_pull_mode(LED_DATA_PIN, true)
    @py32.set_drive_mode(LED_DATA_PIN, false)
    @py32.set_led_count(PIXEL_COUNT)
    show
  end

  def fill(r, g, b)
    @buffer = Array.new(PIXEL_COUNT) { [r, g, b] }
    self
  end

  def set_rgb(i, r, g, b)
    @buffer[i] = [r, g, b]
    self
  end

  def fill_range(start_idx, end_idx, r, g, b)
    i = start_idx
    while i <= end_idx
      @buffer[i] = [r, g, b]
      i += 1
    end
    self
  end

  def fill_left(r, g, b)
    fill_range(LEFT_RANGE.first, LEFT_RANGE.last, r, g, b)
  end

  def fill_right(r, g, b)
    fill_range(RIGHT_RANGE.first, RIGHT_RANGE.last, r, g, b)
  end

  def clear
    fill(0, 0, 0)
  end

  def brightness=(v)
    @brightness = clamp(v, 0, 100)
    self
  end

  def show
    pixels = @buffer.map { |rgb| apply_brightness(rgb[0], rgb[1], rgb[2]) }
    @py32.write_led_ram(pixels)
    @py32.refresh_leds
    self
  end

  def animate_side(side, r, g, b, mode)
    case side
    when :both
      left_animator.set(r, g, b, mode)
      right_animator.set(r, g, b, mode)
    when :left
      left_animator.set(r, g, b, mode)
    when :right
      right_animator.set(r, g, b, mode)
    else
      raise ArgumentError, "unknown side: #{side.inspect}"
    end
    self
  end

  # One-shot pulse: solid color now, off after duration_ms.
  def flash_side(side, r, g, b, duration_ms = 300)
    animate_side(side, r, g, b, :solid)
    @flash_until ||= { left: nil, right: nil }
    end_ms = (Machine.uptime_us / 1000) + duration_ms
    case side
    when :both
      @flash_until[:left]  = end_ms
      @flash_until[:right] = end_ms
    when :left
      @flash_until[:left] = end_ms
    when :right
      @flash_until[:right] = end_ms
    end
    self
  end

  def tick(now_ms)
    left_animator.tick(now_ms)
    right_animator.tick(now_ms)
    return unless @flash_until
    if @flash_until[:left] && now_ms >= @flash_until[:left]
      @flash_until[:left] = nil
      animate_side(:left, 0, 0, 0, :off)
    end
    if @flash_until[:right] && now_ms >= @flash_until[:right]
      @flash_until[:right] = nil
      animate_side(:right, 0, 0, 0, :off)
    end
  end

  private

  def left_animator
    @left_animator ||= Animator.new(self, pixel_range: LEFT_RANGE)
  end

  def right_animator
    @right_animator ||= Animator.new(self, pixel_range: RIGHT_RANGE)
  end

  def apply_brightness(r, g, b)
    [r * @brightness / 100, g * @brightness / 100, b * @brightness / 100]
  end

  def clamp(v, lo, hi)
    v < lo ? lo : (v > hi ? hi : v)
  end
end
