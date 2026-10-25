# Driver for the 12-pixel WS2812 ring, split into a left and a right half, behind the PY32 I/O expander.
# Keeps a pixel buffer and animates each side in solid, blink, breathing or off mode.
class StackchanLed
  # @rbs!
  #   type side = :both | :left | :right
  #   type mode = :solid | :blink | :breathing | :off
  #
  #   interface _Expander
  #     def set_direction: (Integer pin, bool output) -> untyped
  #     def set_pull_mode: (Integer pin, bool up) -> untyped
  #     def set_drive_mode: (Integer pin, bool open_drain) -> untyped
  #     def set_led_count: (Integer count) -> untyped
  #     def write_led_ram: (Array[Array[Integer]] pixels) -> untyped
  #     def refresh_leds: () -> untyped
  #   end
  # @rbs @py32: _Expander
  # @rbs @buffer: Array[Array[Integer]]
  # @rbs @flash_left_until: Integer?
  # @rbs @flash_right_until: Integer?
  # @rbs @left_animator: Animator?
  # @rbs @right_animator: Animator?

  PIXEL_COUNT  = 12
  LED_DATA_PIN = 13

  LEFT_RANGE  = (0..5)
  RIGHT_RANGE = (6..11)

  # Drives the color of one pixel range on the ring for a single mode.
  # Solid and off apply at once; blink and breathing advance on tick.
  class Animator
    # @rbs @led: StackchanLed
    # @rbs @pixel_range: Range[Integer]
    # @rbs @r: Integer
    # @rbs @g: Integer
    # @rbs @b: Integer
    # @rbs @mode: StackchanLed::mode
    # @rbs @phase_start_ms: Integer?
    # @rbs @last_applied: Integer?

    BLINK_HALF_PERIOD_MS = 500
    BREATHING_LUT = [0, 5, 20, 45, 70, 90, 100, 90, 70, 45, 20, 5].freeze
    BREATHING_STEP_MS = 250

    # Creates an animator that paints pixel_range of led, starting off.
    #: (StackchanLed led, pixel_range: Range[Integer]) -> void
    def initialize(led, pixel_range:)
      @led = led
      @pixel_range = pixel_range
      @r = 0
      @g = 0
      @b = 0
      @mode = :off
      @phase_start_ms = nil
    end

    # Sets the color and mode and restarts the animation phase.
    # Solid and off are painted immediately.
    #: (Integer r, Integer g, Integer b, StackchanLed::mode mode) -> void
    def set(r, g, b, mode)
      @r = r
      @g = g
      @b = b
      @mode = mode
      @phase_start_ms = nil
      @last_applied = nil
      apply_immediately
    end

    # Advances blink and breathing to now_ms and repaints when the color changed.
    # Does nothing in solid and off modes.
    #: (Integer now_ms) -> void
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

    # Returns true when the mode is blink or breathing.
    #: () -> bool
    def dynamic?
      @mode == :blink || @mode == :breathing
    end

    # Paints the color for solid and off modes.
    #: () -> void
    def apply_immediately
      case @mode
      when :solid then apply_color(@r, @g, @b)
      when :off   then apply_color(0, 0, 0)
      end
    end

    # Fills the pixel range with the color and shows it.
    #: (Integer r, Integer g, Integer b) -> void
    def apply_color(r, g, b)
      @led.fill_range(@pixel_range.first, @pixel_range.last, r, g, b)
      @led.show
    end

    # Paints the color unless it equals the last painted color.
    #: (Integer r, Integer g, Integer b) -> void
    def apply_color_if_changed(r, g, b)
      rgb = (r << 16) | (g << 8) | b
      return if @last_applied == rgb
      @last_applied = rgb
      apply_color(r, g, b)
    end
  end

  # Configures the PY32 pin for the LED data line, sets the pixel count and clears the ring.
  #: (_Expander py32) -> void
  def initialize(py32)
    @py32 = py32
    @buffer = []
    i = 0
    while i < PIXEL_COUNT
      @buffer << [0, 0, 0]
      i += 1
    end
    @flash_left_until = nil
    @flash_right_until = nil
    @py32.set_direction(LED_DATA_PIN, true)
    @py32.set_pull_mode(LED_DATA_PIN, true)
    @py32.set_drive_mode(LED_DATA_PIN, false)
    @py32.set_led_count(PIXEL_COUNT)
    show
  end

  # Sets pixels start_idx through end_idx inclusive to the color in the buffer without showing them.
  # Returns self.
  #: (Integer start_idx, Integer end_idx, Integer r, Integer g, Integer b) -> self
  def fill_range(start_idx, end_idx, r, g, b)
    i = start_idx
    while i <= end_idx
      @buffer[i] = [r, g, b]
      i += 1
    end
    self
  end

  # Writes the buffer to the expander and refreshes the LEDs.
  # Returns self.
  #: () -> self
  def show
    @py32.write_led_ram(@buffer)
    @py32.refresh_leds
    self
  end

  # Sets the color and mode on the left, right or both sides and cancels a pending flash on those sides.
  # Raises ArgumentError for an unknown side. Returns self.
  #: (side side, Integer r, Integer g, Integer b, mode mode) -> self
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
    @flash_left_until = nil unless side == :right
    @flash_right_until = nil unless side == :left
    self
  end

  # Lights a side solid and blanks it after duration_ms unless animate_side sets that side first.
  # Returns self.
  #: (side side, Integer r, Integer g, Integer b, ?Integer duration_ms) -> self
  def flash_side(side, r, g, b, duration_ms = 300)
    animate_side(side, r, g, b, :solid)
    end_ms = Machine.uptime_us / 1000 + duration_ms
    @flash_left_until = end_ms unless side == :right
    @flash_right_until = end_ms unless side == :left
    self
  end

  # Advances both animators to now_ms and blanks a side whose flash has ended.
  #: (Integer now_ms) -> void
  def tick(now_ms)
    left_animator.tick(now_ms)
    right_animator.tick(now_ms)
    animate_side(:left, 0, 0, 0, :off) if @flash_left_until && now_ms >= @flash_left_until
    animate_side(:right, 0, 0, 0, :off) if @flash_right_until && now_ms >= @flash_right_until
  end

  private

  # Returns the animator for the left pixel range, creating it on first use.
  #: () -> Animator
  def left_animator
    @left_animator ||= Animator.new(self, pixel_range: LEFT_RANGE)
  end

  # Returns the animator for the right pixel range, creating it on first use.
  #: () -> Animator
  def right_animator
    @right_animator ||= Animator.new(self, pixel_range: RIGHT_RANGE)
  end
end
