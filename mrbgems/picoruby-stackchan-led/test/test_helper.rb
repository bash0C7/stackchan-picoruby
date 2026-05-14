$LOAD_PATH.unshift File.expand_path("../mrblib", __dir__)
$LOAD_PATH.unshift File.expand_path(".", __dir__)

require "test/unit"

class FakePY32
  attr_reader :led_count_calls, :led_ram_calls, :refresh_calls,
              :direction_calls, :pull_mode_calls, :drive_mode_calls

  def initialize
    @led_count_calls = []
    @led_ram_calls = []
    @refresh_calls = 0
    @direction_calls = []
    @pull_mode_calls = []
    @drive_mode_calls = []
  end

  def set_led_count(n); @led_count_calls << n; end
  def write_led_ram(pixels); @led_ram_calls << pixels.map(&:dup); end
  def refresh_leds; @refresh_calls += 1; end

  def set_direction(pin, value); @direction_calls << [pin, value]; end
  def set_pull_mode(pin, value); @pull_mode_calls << [pin, value]; end
  def set_drive_mode(pin, value); @drive_mode_calls << [pin, value]; end
end

require "stackchan_led"
require "stackchan_led/animator"
