module StackchanProtocol
  # FrameParser is the only public class — see frame_parser.rb.
  # Note: no `require 'stackchan_protocol/frame_parser'` here. PicoRuby
  # mrbgem build compiles all mrblib/**/*.rb into the gem automatically;
  # an explicit require would raise LoadError on device (mrblib paths are
  # not on the device's $LOAD_PATH).
end
