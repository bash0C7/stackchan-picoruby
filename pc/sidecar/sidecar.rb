# CRuby AI/voice sidecar for the PicoRuby StackChan daemon.
#
# Apple Foundation Model (rb-foundation-model-mac, in-process Swift) and the
# macOS `say`/`afconvert` TTS pipeline cannot run under PicoRuby, so they live
# here in CRuby and are reached from the PicoRuby daemon over picoruby-drb
# (TCP loopback — picoruby-drb has no Unix-socket transport). Marshal wire is
# byte-compatible across CRuby<->PicoRuby (verified PoC).
#
# Clean split vs the old in-daemon design: the sidecar returns DATA ONLY
# (reply text / mu-law bytes) and never touches BLE. The daemon owns the BLE
# link and does the device writes (chat reply frame, audio streaming).
#
# Verbs:
#   respond(prompt, ctx)   -> reply String (FM)
#   synthesize(text, gain) -> mu-law byte String (8 kHz mono)
#   ping                   -> "pong"
#
# Run:  ruby pc/sidecar/sidecar.rb [port]        # real FM + say/afconvert
#       STACKCHAN_SIDECAR_STUB=1 ruby ...        # deterministic stub (no FM/say)
# Run the REAL sidecar under pc/stackchan's bundle (FM + drb live there):
#   BUNDLE_GEMFILE=pc/stackchan/Gemfile bundle exec ruby pc/sidecar/sidecar.rb
require "drb"

PORT = (ARGV[0] || ENV["STACKCHAN_SIDECAR_PORT"] || "8788").to_i
STUB = ENV["STACKCHAN_SIDECAR_STUB"] == "1"

# Reuse the CRuby Tts (say -> afconvert -> mu-law). The shared layer's persona
# lives here too so the sidecar has no dependency on the BLE-coupled Companion.
$LOAD_PATH.unshift File.expand_path("../stackchan/lib", __dir__)
# Namespace root so stackchan/voice/*.rb (which reopen `module Stackchan::Voice`)
# can be required without pulling in the BLE-coupled lib/stackchan.rb chain.
module Stackchan; end

module StackchanSidecar
  PERSONA = "あなたは小さな卓上ロボットの『スタックチャン』です。" \
            "頭を撫でられたり、話しかけられたりしたら、その状況にあわせて" \
            "日本語で1〜2文の短い返事をしてください。19文字以内に収まる長さで。" \
            "ただの相槌や『はい』で済ませず、相手や場の状況に触れた具体的な返事をしてください。"

  class Service
    def initialize(stub: false)
      @stub = stub
      unless @stub
        require "foundation_model_mac"
        require "stackchan/voice/tts"
        @session = AppleFoundationModel::Session.new(instructions: PERSONA)
      end
    end

    def ping
      "pong"
    end

    # prompt: String, ctx: Hash (symbol keys, no Time — the PicoRuby daemon
    # cannot Marshal a Time). Returns the reply text (the daemon frames + sends).
    def respond(prompt, ctx = {})
      # Strings arriving from PicoRuby over Marshal are tagged ASCII-8BIT;
      # re-tag as UTF-8 at this boundary so interpolation with our literals
      # doesn't raise Encoding::CompatibilityError.
      prompt = u8(prompt)
      ctx = normalize_ctx(ctx)
      if @stub
        return "stub返答:#{ctx[:touch_zone_label] || prompt}"[0, 19]
      end
      situation = build_situation(ctx)
      full = situation.empty? ? prompt : "#{situation}\n\n問いかけ: #{prompt}"
      @session.respond(to: full)
    rescue => e
      warn "[sidecar] respond error: #{e.class}: #{e.message}"
      nil
    end

    # text -> 8 kHz mono mu-law bytes. gain defaults to the Tts default.
    def synthesize(text, gain = nil)
      text = u8(text)
      if @stub
        # Deterministic silent clip sized from the text so the bridge/streamer
        # can be exercised without say/afconvert.
        return "\xFF".b * (text.to_s.length * 80)
      end
      opts = {}
      opts[:gain] = gain if gain
      Stackchan::Voice::Tts.new(**opts).synthesize(text)
    rescue => e
      warn "[sidecar] synthesize error: #{e.class}: #{e.message}"
      nil
    end

    private

    # Re-tag a PicoRuby-origin (ASCII-8BIT) String as UTF-8. Non-strings pass through.
    def u8(s)
      s.is_a?(String) ? s.dup.force_encoding("UTF-8") : s
    end

    def normalize_ctx(ctx)
      return {} unless ctx.is_a?(Hash)
      out = {}
      ctx.each { |k, v| out[k] = u8(v) }
      out
    end

    def build_situation(ctx)
      return "" unless ctx.is_a?(Hash) && !ctx.empty?
      parts = []
      parts << "今の表情: #{ctx[:last_face]}"               if ctx[:last_face]
      parts << "自分が直前に言ったこと: 「#{ctx[:last_say]}」"   if ctx[:last_say]
      parts << "直前に相手から聞いた話: 「#{ctx[:last_heard]}」" if ctx[:last_heard]
      if ctx[:touch_zone_label]
        parts << "今、#{ctx[:touch_zone_label]}を触られた"
      elsif ctx[:touch_zone]
        parts << "今、頭の zone=#{ctx[:touch_zone]} を触られた"
      end
      parts.empty? ? "" : ("今の状況:\n- " + parts.join("\n- "))
    end
  end
end

service = StackchanSidecar::Service.new(stub: STUB)
DRb.start_service("druby://127.0.0.1:#{PORT}", service)
$stdout.sync = true
puts "[sidecar] #{STUB ? 'STUB' : 'REAL'} listening on druby://127.0.0.1:#{PORT}"
DRb.thread.join
