# Host boot for the PicoRuby daemon using the FakeBleClient (no real device).
#   picoruby boot_daemon.rb <repo-root> [port]
# On the deployment VM (shared gem compiled in) the gem `load`s are unnecessary
# and the real BLE client replaces FakeBleClient.
root = ARGV[0] || "."
port = (ARGV[1] || "8787").to_i
# On a deployment VM the shared gem is compiled in (Stackchan already defined);
# only load the mrblib when running on a plain VM without it baked in.
unless Object.const_defined?(:Stackchan)
  [
    "stackchan.rb",
    "stackchan/ble/face_table.rb",
    "stackchan/ble/led_color_table.rb",
    "stackchan/ble/hsb_to_rgb.rb",
    "stackchan/ble/frame_codec.rb",
    "stackchan/ble/send_builder.rb",
    "stackchan/ai/frame_text.rb",
  ].each { |f| load "#{root}/mrbgems/picoruby-stackchan-shared/mrblib/#{f}" }
end
require "drb"
load "#{root}/pc/stackchan-pico/app/drb_eintr_retry.rb"
load "#{root}/pc/stackchan-pico/app/calib.rb"
load "#{root}/pc/stackchan-pico/app/daemon_app.rb"
load "#{root}/pc/stackchan-pico/app/fake_ble.rb"

ble = FakeBleClient.new
daemon = Stackchan::Daemon.new(ble: ble, port: port)
daemon.start
daemon.join
