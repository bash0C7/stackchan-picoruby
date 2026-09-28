root = ARGV[0] || "."
port = (ARGV[1] || "8787").to_i
name_prefix = ARGV[2] || "StackChan"
sidecar_port = (ARGV[3] || "8788").to_i
load "#{root}/mrbgems/picoruby-stackchan-protocol/mrblib/stackchan-protocol.rb"
load "#{root}/mrbgems/picoruby-stackchan-protocol/mrblib/stackchan-protocol/frame_codec.rb"
load "#{root}/mrbgems/picoruby-stackchan-protocol/mrblib/stackchan-protocol/frame_parser.rb"
load "#{root}/mrbgems/picoruby-stackchan-protocol/mrblib/stackchan-protocol/frame_text.rb"
require "drb"
load "#{root}/pc/stackchan-pico/app/drb_eintr_retry.rb"
load "#{root}/mrbgems/picoruby-drb-ble/mrblib/drb-ble.rb"
load "#{root}/mrbgems/picoruby-stackchan-controller/mrblib/stackchan-controller.rb"
load "#{root}/mrbgems/picoruby-stackchan-controller/mrblib/stackchan-controller/errors.rb"
load "#{root}/mrbgems/picoruby-stackchan-controller/mrblib/stackchan-controller/send_builder.rb"
load "#{root}/mrbgems/picoruby-stackchan-controller/mrblib/stackchan-controller/nus.rb"
load "#{root}/mrbgems/picoruby-stackchan-controller/mrblib/stackchan-controller/central.rb"
load "#{root}/mrbgems/picoruby-stackchan-controller/mrblib/stackchan-controller/calibration.rb"
load "#{root}/mrbgems/picoruby-stackchan-controller/mrblib/stackchan-controller/link.rb"
load "#{root}/mrbgems/picoruby-stackchan-controller/mrblib/stackchan-controller/session.rb"
load "#{root}/mrbgems/picoruby-stackchan-controller/mrblib/stackchan-controller/args.rb"
load "#{root}/mrbgems/picoruby-stackchan-controller/mrblib/stackchan-controller/builder.rb"
load "#{root}/mrbgems/picoruby-stackchan-controller/mrblib/stackchan-controller/daemon.rb"

if name_prefix == "fake"
  load "#{root}/pc/stackchan-pico/app/fake_ble.rb"
else
  load "#{root}/mrbgems/picoruby-stackchan-controller/mrblib/stackchan-controller/radio.rb"
end
load "#{root}/apps/mac/app.rb"

begin
  App.serve(port: port, host: "127.0.0.1", name_prefix: name_prefix,
            sidecar_uri: "druby://127.0.0.1:#{sidecar_port}")
rescue => e
  $stderr.write("[stackchand] FATAL #{e.class}: #{e.message}\n")
  $stderr.flush
end
