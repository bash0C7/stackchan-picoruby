$LOAD_PATH.unshift File.expand_path("../mrblib", __dir__)
$LOAD_PATH.unshift File.expand_path(".", __dir__)

# PicoRuby shim: 'spi' / 'gpio' are runtime built-ins; no-op the require under CRuby.
$LOADED_FEATURES << "spi"  unless $LOADED_FEATURES.include?("spi")
$LOADED_FEATURES << "gpio" unless $LOADED_FEATURES.include?("gpio")

# PicoRuby shim: Machine.delay_ms is a runtime built-in.
unless defined?(Machine)
  module Machine
    def self.delay_ms(_ms); end
    def self.uptime_us; 0; end
  end
end

# PicoRuby shim: SPI/GPIO classes are runtime built-ins. We don't need real
# ones in host tests, only the FakeSPI/FakeGPIO doubles that callers inject.
class SPI;  end unless defined?(SPI)
class GPIO; end unless defined?(GPIO)

require "test/unit"
require "spi_mock"
require "gpio_mock"
