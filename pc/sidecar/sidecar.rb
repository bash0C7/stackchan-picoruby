# CRuby AI/voice sidecar (Apple Foundation Model and say/afconvert cannot run
# under PicoRuby). Reached from the daemon over picoruby-drb; returns data only.
#
# Verbs: respond(prompt, ctx) -> String|nil, synthesize(text, gain, rate) -> mu-law String|nil, ping -> "pong"
# Run:   BUNDLE_GEMFILE=pc/stackchan/Gemfile bundle exec ruby pc/sidecar/sidecar.rb [port]
#        STACKCHAN_SIDECAR_STUB=1 / STACKCHAN_SIDECAR_STUB_DELAY_S=N / STACKCHAN_SIDECAR_TIMEOUT_S=N
require "drb"
require_relative "service"

PORT    = (ARGV[0] || ENV["STACKCHAN_SIDECAR_PORT"] || "8788").to_i
STUB    = ENV["STACKCHAN_SIDECAR_STUB"] == "1"
DELAY_S = ENV["STACKCHAN_SIDECAR_STUB_DELAY_S"] && ENV["STACKCHAN_SIDECAR_STUB_DELAY_S"].to_f

$LOAD_PATH.unshift File.expand_path("../stackchan/lib", __dir__)
# Namespace root so stackchan/voice/*.rb can be required without lib/stackchan.rb.
module Stackchan; end

service = StackchanSidecar::Service.new(stub: STUB, delay_s: DELAY_S)
DRb.start_service("druby://127.0.0.1:#{PORT}", service)
$stdout.sync = true
puts "[sidecar] #{STUB ? 'STUB' : 'REAL'} listening on druby://127.0.0.1:#{PORT}"
DRb.thread.join
