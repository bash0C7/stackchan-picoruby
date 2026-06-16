# Host stub for PY32IOExpander, exercising only the LED-path methods that
# StackchanLed#initialize / #show call. Records write_led_ram payloads so
# tests can assert the post-brightness pixel buffer pushed to the device.
class FakePy32
  attr_reader :calls, :last_pixels

  def initialize
    @calls = []
    @last_pixels = nil
  end

  def set_direction(pin, out)
    @calls << [:set_direction, [pin, out]]
  end

  def set_pull_mode(pin, on)
    @calls << [:set_pull_mode, [pin, on]]
  end

  def set_drive_mode(pin, on)
    @calls << [:set_drive_mode, [pin, on]]
  end

  def set_led_count(count)
    @calls << [:set_led_count, [count]]
  end

  def write_led_ram(pixels)
    @last_pixels = pixels
    @calls << [:write_led_ram, [pixels]]
  end

  def refresh_leds
    @calls << [:refresh_leds, []]
  end
end
