# Daemon boot.  picoruby boot_daemon.rb <repo-root> [port] [name-prefix|fake]
# "fake" runs FakeBleClient (no radio) instead of the real BLE central.
root = ARGV[0] || "."
port = (ARGV[1] || "8787").to_i
name_prefix = ARGV[2] || "StackChan"
# Skip the mrblib loads when the shared gem is compiled into the VM.
unless Object.const_defined?(:Stackchan)
  [
    "stackchan/ble/errors.rb",
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

if name_prefix == "fake"
  load "#{root}/pc/stackchan-pico/app/fake_ble.rb"
  ble = FakeBleClient.new
else
  load "#{root}/pc/stackchan-pico/app/ble_client.rb"
  ble = StackchanCentral.new(name_prefix: name_prefix)
end

daemon = Stackchan::Daemon.new(ble: ble, port: port)
begin
  daemon.start
  daemon.join
rescue => e
  # PicoRuby's uncaught-exception handling prints nothing and exits 0.
  $stderr.write("[stackchand] FATAL #{e.class}: #{e.message}\n")
  $stderr.flush
end
