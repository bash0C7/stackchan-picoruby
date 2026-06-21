# CRuby reference loader: pull ONLY the pure modules from pc/stackchan
# (avoid stackchan/ble.rb which require_relatives the native corebluetooth_mac
# client). Predefine the namespace so the `module Stackchan::*` reopenings
# resolve, then exercise the same probe.
#   ruby load_cruby.rb <repo-root>
root = ARGV[0] || "."
module Stackchan; end
$LOAD_PATH.unshift File.join(root, "pc/stackchan/lib")
require "stackchan/ble/send_builder"   # pulls face_table, led_color_table, frame_codec, hsb_to_rgb
require "stackchan/ai/frame_text"
load File.join(root, "repro/shared-parity/probe.rb")
