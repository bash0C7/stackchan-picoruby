# frozen_string_literal: true

require "timeout"

# Sidecar that answers chat prompts with Apple Foundation Models and synthesizes speech.
module StackchanSidecar
  PERSONA = "あなたは小さな卓上ロボットの『スタックチャン』です。" \
            "頭を撫でられたり、話しかけられたりしたら、その状況にあわせて" \
            "日本語で1〜2文の短い返事をしてください。19文字以内に収まる長さで。" \
            "ただの相槌や『はい』で済ませず、相手や場の状況に触れた具体的な返事をしてください。"

  # DRb front of the sidecar: generates a reply text and synthesizes mu-law audio.
  class Service
    # @rbs @stub: bool
    # @rbs @delay_s: Numeric?
    # @rbs @timeout_s: Integer
    # @rbs @session: untyped

    DEFAULT_TIMEOUT_S = (ENV["STACKCHAN_SIDECAR_TIMEOUT_S"] || "60").to_i

    # Builds the service; unless stub, loads the Foundation Models session and the TTS.
    #: (?stub: bool, ?delay_s: Numeric?, ?timeout_s: Integer?) -> void
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

    # Returns the model reply for prompt with the robot state in ctx, or nil on error or timeout.
    #: (String prompt, ?Hash[untyped, untyped] ctx) -> String?
    def respond(prompt, ctx = {})
      prompt = u8(prompt)
      ctx = normalize_ctx(ctx)
      Timeout.timeout(@timeout_s) do
        if @stub
          sleep(@delay_s) if @delay_s
          next "stub返答:#{prompt}"[0, 19]
        end
        situation = build_situation(ctx)
        full = situation.empty? ? prompt : "#{situation}\n\n問いかけ: #{prompt}"
        @session.respond(to: full)
      end
    rescue => e
      warn "[sidecar] respond error: #{e.class}: #{e.message}"
      nil
    end

    # Returns mu-law 8 kHz bytes speaking text, or nil on error or timeout.
    #: (String text, ?Float? gain, ?Integer? rate) -> String?
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

    # Returns a String relabeled as UTF-8; other values pass through.
    #: (untyped s) -> untyped
    def u8(s)
      s.is_a?(String) ? s.dup.force_encoding("UTF-8") : s
    end

    # Returns ctx with every value relabeled as UTF-8, or an empty Hash when ctx is not a Hash.
    #: (untyped ctx) -> Hash[untyped, untyped]
    def normalize_ctx(ctx)
      return {} unless ctx.is_a?(Hash)
      out = {}
      ctx.each { |k, v| out[k] = u8(v) }
      out
    end

    # Returns the situation text from last_face, last_say and last_heard, or an empty String.
    #: (Hash[untyped, untyped] ctx) -> String
    def build_situation(ctx)
      return "" if ctx.empty?
      parts = []
      parts << "今の表情: #{ctx[:last_face]}"               if ctx[:last_face]
      parts << "自分が直前に言ったこと: 「#{ctx[:last_say]}」"   if ctx[:last_say]
      parts << "直前に相手から聞いた話: 「#{ctx[:last_heard]}」" if ctx[:last_heard]
      parts.empty? ? "" : ("今の状況:\n- " + parts.join("\n- "))
    end
  end
end
