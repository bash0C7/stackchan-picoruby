root = ARGV[0] || "."
port = (ARGV[1] || "8787").to_i
name_prefix = ARGV[2] || "StackChan"
load "#{root}/mrbgems/picoruby-stackchan-protocol/mrblib/stackchan-protocol.rb"
load "#{root}/mrbgems/picoruby-stackchan-protocol/mrblib/stackchan-protocol/frame_codec.rb"
load "#{root}/mrbgems/picoruby-stackchan-protocol/mrblib/stackchan-protocol/frame_parser.rb"
load "#{root}/mrbgems/picoruby-stackchan-protocol/mrblib/stackchan-protocol/frame_text.rb"
load "#{root}/mrbgems/picoruby-stackchan-shared/mrblib/stackchan/ble/errors.rb"
load "#{root}/mrbgems/picoruby-stackchan-shared/mrblib/stackchan/ble/send_builder.rb"
require "drb"
load "#{root}/pc/stackchan-pico/app/drb_eintr_retry.rb"
load "#{root}/mrbgems/picoruby-drb-ble/mrblib/drb-ble.rb"
load "#{root}/mrbgems/picoruby-stackchan-controller/mrblib/stackchan-controller.rb"
load "#{root}/mrbgems/picoruby-stackchan-controller/mrblib/stackchan-controller/nus.rb"
load "#{root}/mrbgems/picoruby-stackchan-controller/mrblib/stackchan-controller/central.rb"
load "#{root}/mrbgems/picoruby-stackchan-controller/mrblib/stackchan-controller/calibration.rb"
load "#{root}/mrbgems/picoruby-stackchan-controller/mrblib/stackchan-controller/daemon.rb"

if name_prefix == "fake"
  load "#{root}/pc/stackchan-pico/app/fake_ble.rb"
  ble = FakeBleClient.new
else
  load "#{root}/mrbgems/picoruby-stackchan-controller/mrblib/stackchan-controller/radio.rb"
  ble = StackChan::Controller::Central.new(name_prefix: name_prefix)
end

daemon = StackChan::Controller::Daemon.new(ble: ble, port: port)
begin
  daemon.start
  daemon.join
rescue => e
  $stderr.write("[stackchand] FATAL #{e.class}: #{e.message}\n")
  $stderr.flush
end
