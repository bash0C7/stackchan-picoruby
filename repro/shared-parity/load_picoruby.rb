# PicoRuby loader: load the shared gem mrblib files in dependency order,
# then run the shared probe. Run with the host picoruby binary.
#   picoruby load_picoruby.rb <repo-root-abs-path>
root = ARGV[0] || "."
$stdout.write("LOADER_START root=#{root}\n"); $stdout.flush
[
  "stackchan.rb",
  "stackchan/ble/face_table.rb",
  "stackchan/ble/led_color_table.rb",
  "stackchan/ble/hsb_to_rgb.rb",
  "stackchan/ble/frame_codec.rb",
  "stackchan/ble/send_builder.rb",
  "stackchan/ai/frame_text.rb",
].each do |f|
  load "#{root}/mrbgems/picoruby-stackchan-shared/mrblib/#{f}"
end
$stdout.write("MRBLIB_LOADED\n"); $stdout.flush
load "#{root}/repro/shared-parity/probe.rb"
$stdout.write("PROBE_DONE\n"); $stdout.flush
