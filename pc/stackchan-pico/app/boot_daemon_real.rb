# Device boot for the PicoRuby daemon using the REAL picoruby-ble central
# client (StackchanCentral in ble_client.rb) against a physical StackChan,
# instead of FakeBleClient. Requires the device already advertising as
# "StackChan*" and a VM built with the darwin-ble backend (deployment VM:
# build-stackchan-pc/host/bin/picoruby).
#   picoruby boot_daemon_real.rb <repo-root> [port] [name-prefix]
root = ARGV[0] || "."
port = (ARGV[1] || "8787").to_i
name_prefix = ARGV[2] || "StackChan"
# On a deployment VM the shared gem is compiled in (Stackchan already defined);
# only load the mrblib when running on a plain VM without it baked in.
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
load "#{root}/pc/stackchan-pico/app/ble_client.rb"

ble = StackchanCentral.new(name_prefix: name_prefix)
daemon = Stackchan::Daemon.new(ble: ble, port: port)
begin
  daemon.start
  daemon.join
rescue => e
  # PicoRuby's top-level uncaught-exception handling is silent (prints
  # nothing, exits 0), which would otherwise leave daemon.log empty on a
  # failed connect (e.g. no matching advertiser within
  # StackchanCentral::CONNECT_TIMEOUT_MS) — surface it explicitly.
  $stderr.write("[stackchand] FATAL #{e.class}: #{e.message}\n")
  $stderr.flush
end
