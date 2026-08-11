# CRuby AI/voice sidecar for the PicoRuby StackChan daemon.
#
# Apple Foundation Model (rb-foundation-model-mac, in-process Swift) and the
# macOS `say`/`afconvert` TTS pipeline cannot run under PicoRuby, so they live
# here in CRuby and are reached from the PicoRuby daemon over picoruby-drb
# (TCP loopback -- picoruby-drb has no Unix-socket transport). Marshal wire is
# byte-compatible across CRuby<->PicoRuby (verified PoC).
#
# Clean split vs the old in-daemon design: the sidecar returns DATA ONLY
# (reply text / mu-law bytes) and never touches BLE. The daemon owns the BLE
# link and does the device writes (chat reply frame, audio streaming).
#
# Verbs:
#   respond(prompt, ctx)         -> reply String (FM), or nil (error/timeout)
#   synthesize(text, gain, rate) -> mu-law byte String (8 kHz mono), or nil
#   ping                         -> "pong"
#
# Run:  ruby pc/sidecar/sidecar.rb [port]         # real FM + say/afconvert
#       STACKCHAN_SIDECAR_STUB=1 ruby ...         # deterministic stub (no FM/say)
#       STACKCHAN_SIDECAR_STUB_DELAY_S=N ruby ... # stub sleeps N sec before replying
#       STACKCHAN_SIDECAR_TIMEOUT_S=N ruby ...    # override the 60s call bound
# Run the REAL sidecar under pc/stackchan's bundle (FM + drb live there):
#   BUNDLE_GEMFILE=pc/stackchan/Gemfile bundle exec ruby pc/sidecar/sidecar.rb
require "drb"
require_relative "service"

PORT    = (ARGV[0] || ENV["STACKCHAN_SIDECAR_PORT"] || "8788").to_i
STUB    = ENV["STACKCHAN_SIDECAR_STUB"] == "1"
DELAY_S = ENV["STACKCHAN_SIDECAR_STUB_DELAY_S"] && ENV["STACKCHAN_SIDECAR_STUB_DELAY_S"].to_f

# Reuse the CRuby Tts (say -> afconvert -> mu-law). The shared layer's persona
# lives in service.rb so the sidecar has no dependency on the BLE-coupled Companion.
$LOAD_PATH.unshift File.expand_path("../stackchan/lib", __dir__)
# Namespace root so stackchan/voice/*.rb (which reopen `module Stackchan::Voice`)
# can be required without pulling in the BLE-coupled lib/stackchan.rb chain.
module Stackchan; end

service = StackchanSidecar::Service.new(stub: STUB, delay_s: DELAY_S)
DRb.start_service("druby://127.0.0.1:#{PORT}", service)
$stdout.sync = true
puts "[sidecar] #{STUB ? 'STUB' : 'REAL'} listening on druby://127.0.0.1:#{PORT}"
DRb.thread.join
