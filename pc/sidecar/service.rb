# frozen_string_literal: true

# StackchanSidecar::Service -- the CRuby AI/voice sidecar's DRb-facing
# object. Extracted from sidecar.rb (the process bootstrap) so it can be
# exercised directly in tests without starting a DRb server.
require "timeout"

module StackchanSidecar
  PERSONA = "あなたは小さな卓上ロボットの『スタックチャン』です。" \
            "頭を撫でられたり、話しかけられたりしたら、その状況にあわせて" \
            "日本語で1〜2文の短い返事をしてください。19文字以内に収まる長さで。" \
            "ただの相槌や『はい』で済ませず、相手や場の状況に触れた具体的な返事をしてください。"

  class Service
    # respond/synthesize each bound their real work in Timeout.timeout so a
    # stuck Apple Intelligence call or a stuck say/afconvert TTS pipeline
    # can't block this method forever -- the PicoRuby daemon's DRb client
    # read has no yield point of its own (see docs/superpowers/specs/
    # 2026-08-11-sidecar-call-timeout-design.md), so an unbounded sidecar
    # response would freeze the whole daemon VM. timeout_s/delay_s are
    # constructor overrides (not just ENV) so tests can force an exact, fast
    # timeout without waiting the real default.
    DEFAULT_TIMEOUT_S = (ENV["STACKCHAN_SIDECAR_TIMEOUT_S"] || "60").to_i

    def initialize(stub: false, delay_s: nil, timeout_s: nil)
      @stub      = stub
      @delay_s   = delay_s
      @timeout_s = timeout_s || DEFAULT_TIMEOUT_S
      unless @stub
        require "foundation_model_mac"
        require "stackchan/voice/tts"
        @session = AppleFoundationModel::Session.new(instructions: PERSONA)
      end
    end

    def ping
      "pong"
    end

    # prompt: String, ctx: Hash (symbol keys, no Time -- the PicoRuby daemon
    # cannot Marshal a Time). Returns the reply text (the daemon frames +
    # sends), or nil on any failure including a Timeout::Error.
    def respond(prompt, ctx = {})
      # Strings arriving from PicoRuby over Marshal are tagged ASCII-8BIT;
      # re-tag as UTF-8 at this boundary so interpolation with our literals
      # doesn't raise Encoding::CompatibilityError.
      prompt = u8(prompt)
      ctx = normalize_ctx(ctx)
      Timeout.timeout(@timeout_s) do
        if @stub
          sleep(@delay_s) if @delay_s
          next "stub返答:#{ctx[:touch_zone_label] || prompt}"[0, 19]
        end
        situation = build_situation(ctx)
        full = situation.empty? ? prompt : "#{situation}\n\n問いかけ: #{prompt}"
        @session.respond(to: full)
      end
    rescue => e
      warn "[sidecar] respond error: #{e.class}: #{e.message}"
      nil
    end

    # text -> 8 kHz mono mu-law bytes, or nil on any failure including a
    # Timeout::Error. gain/rate default to the Tts defaults.
    def synthesize(text, gain = nil, rate = nil)
      text = u8(text)
      Timeout.timeout(@timeout_s) do
        if @stub
          sleep(@delay_s) if @delay_s
          next "\xFF".b * (text.to_s.length * 80)
        end
        opts = {}
        opts[:gain] = gain if gain
        opts[:rate] = rate if rate
        Stackchan::Voice::Tts.new(**opts).synthesize(text)
      end
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
