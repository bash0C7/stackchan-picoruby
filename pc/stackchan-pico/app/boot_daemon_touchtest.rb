# Host boot variant that injects synthetic head-touches from a Task, to verify
# the touch path (on_unsolicited -> @touch_events -> subscribe_touch -> remote
# block over drb) without a real device.
#   picoruby boot_daemon_touchtest.rb <repo-root> [port]
root = ARGV[0] || "."
port = (ARGV[1] || "8787").to_i
unless Object.const_defined?(:Stackchan)
  [
    "stackchan.rb",
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
load "#{root}/pc/stackchan-pico/app/daemon_app.rb"
load "#{root}/pc/stackchan-pico/app/fake_ble.rb"

ble = FakeBleClient.new
daemon = Stackchan::Daemon.new(ble: ble, port: port)
daemon.start

# Inject a touch on zones 0,1,2 once per second so a `touch listen` session sees
# events surface through the daemon's queue and drb callback.
Task.new(name: "touch-injector") do
  zone = 0
  loop do
    sleep 1
    ble.inject_touch(zone)
    zone = (zone + 1) % 3
  end
end

daemon.join
