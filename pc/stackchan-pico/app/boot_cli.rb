root = ARGV[0] || "."
port = (ARGV[1] || "8787").to_i
verb_args = ARGV[2, ARGV.length - 2] || []
require "drb"
load "#{root}/pc/stackchan-pico/app/drb_eintr_retry.rb"
load "#{root}/mrbgems/picoruby-stackchan-controller/mrblib/stackchan-controller/calibration.rb"
load "#{root}/mrbgems/picoruby-stackchan-controller/mrblib/stackchan-controller/cli.rb"
code = StackChan::Controller::CLI.run(verb_args, port: port)
exit(code || 0)
