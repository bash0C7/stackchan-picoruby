$LOAD_PATH.unshift File.expand_path("../mrblib", __dir__)
$LOAD_PATH.unshift File.expand_path(".", __dir__)

# PicoRuby shim: ILI9342 is supplied by the picoruby-ili9342 mrbgem at runtime.
# For host tests we don't need the real class — the FakeDisplay records calls.
unless defined?(ILI9342)
  class ILI9342
    module Color
      BLACK = 0x0000
      WHITE = 0xFFFF
    end
  end
end

require "test/unit"
require "fake_display"
require "fake_stdio"
require "fake_led"
require "stackchan_protocol"
require "stackchan_protocol/frame_parser"
require "stackchan_protocol/dispatcher"
