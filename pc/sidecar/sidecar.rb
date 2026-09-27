require "drb"
require_relative "service"

PORT    = (ARGV[0] || "8788").to_i
STUB    = ENV["STACKCHAN_SIDECAR_STUB"] == "1"
DELAY_S = ENV["STACKCHAN_SIDECAR_STUB_DELAY_S"] && ENV["STACKCHAN_SIDECAR_STUB_DELAY_S"].to_f

$LOAD_PATH.unshift File.expand_path("../stackchan/lib", __dir__)

service = StackchanSidecar::Service.new(stub: STUB, delay_s: DELAY_S)
DRb.start_service("druby://127.0.0.1:#{PORT}", service)
$stdout.sync = true
puts "[sidecar] #{STUB ? 'STUB' : 'REAL'} listening on druby://127.0.0.1:#{PORT}"
DRb.thread.join
