$LOAD_PATH.unshift File.expand_path("../mrblib", __dir__)
$LOAD_PATH.unshift File.expand_path(".", __dir__)

# Stub PY32IOExpander require so the gem can `require 'py32_io_expander'`
# without the real gem being installed in host CRuby. Tests inject FakePY32.
$LOADED_FEATURES << "py32_io_expander" unless $LOADED_FEATURES.include?("py32_io_expander")
unless defined?(PY32IOExpander)
  class PY32IOExpander
    def initialize(*); end
  end
end

require "test/unit"

class FakePY32
  attr_reader :led_count_calls, :led_ram_calls, :refresh_calls

  def initialize
    @led_count_calls = []
    @led_ram_calls = []
    @refresh_calls = 0
  end

  def set_led_count(n); @led_count_calls << n; end
  def write_led_ram(pixels); @led_ram_calls << pixels.map(&:dup); end
  def refresh_leds; @refresh_calls += 1; end
end

require "stackchan_led"
require "stackchan_led/animator"
