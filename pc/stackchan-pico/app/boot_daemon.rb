root = ARGV[0] || "."
port = (ARGV[1] || "8787").to_i
name_prefix = ARGV[2] || "StackChan"
load "#{root}/mrbgems/picoruby-stackchan-shared/mrblib/stackchan/ble/errors.rb"
load "#{root}/mrbgems/picoruby-stackchan-shared/mrblib/stackchan/ble/frame_codec.rb"
load "#{root}/mrbgems/picoruby-stackchan-shared/mrblib/stackchan/ble/send_builder.rb"
load "#{root}/mrbgems/picoruby-stackchan-shared/mrblib/stackchan/ai/frame_text.rb"
require "drb"
load "#{root}/pc/stackchan-pico/app/drb_eintr_retry.rb"
load "#{root}/mrbgems/picoruby-drb-ble/mrblib/drb-ble.rb"
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
  $stderr.write("[stackchand] FATAL #{e.class}: #{e.message}\n")
  $stderr.flush
end
