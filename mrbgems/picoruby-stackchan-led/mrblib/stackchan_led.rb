require 'py32-io-expander'

class StackchanLed
  PIXEL_COUNT  = 12
  LED_DATA_PIN = 13

  # Left/right physical pixel index split (draft assumption — verify visually
  # via rake r2p2:ble_control_smoke SIDE=left / SIDE=right and adjust if the
  # physical wraparound differs).
  LEFT_RANGE  = (0..5)
  RIGHT_RANGE = (6..11)

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

  def animate(r, g, b, mode)
    animator.set(r, g, b, mode)
    self
  end

  def tick(now_ms)
    animator.tick(now_ms)
  end

  private

  def animator
    @animator ||= Animator.new(self)
  end

  def apply_brightness(r, g, b)
    [r * @brightness / 100, g * @brightness / 100, b * @brightness / 100]
  end

  def clamp(v, lo, hi)
    v < lo ? lo : (v > hi ? hi : v)
  end
end
