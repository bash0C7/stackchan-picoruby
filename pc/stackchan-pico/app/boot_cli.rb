# Host boot for the PicoRuby CLI.
#   picoruby boot_cli.rb <repo-root> <port> <verb> [args...]
root = ARGV[0] || "."
port = (ARGV[1] || "8787").to_i
verb_args = ARGV[2, ARGV.length - 2] || []
require "drb"
load "#{root}/pc/stackchan-pico/app/drb_eintr_retry.rb"
load "#{root}/pc/stackchan-pico/app/cli_app.rb"
code = Stackchan::CLI.run(verb_args, port: port)
exit(code || 0)
