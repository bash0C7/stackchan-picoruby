require "foundation_model_mac"
require_relative "frame_text"

module Stackchan
  module AI
    # AI companion: prompts an Apple Foundation Model session and pushes the
    # reply to the device as a single <F:n,text:...> frame. Receives an
    # already-connected Stackchan::BLE::Client (daemon owns the connection).
    class Companion
      PERSONA = "あなたは小さな卓上ロボットの『スタックチャン』です。" \
                "頭を撫でられたり、話しかけられたりしたら、その状況にあわせて" \
                "日本語で1〜2文の短い返事をしてください。19文字以内に収まる長さで。" \
                "ただの相槌や『はい』で済ませず、相手や場の状況に触れた具体的な返事をしてください。"
      EMOTION_FACE = { joy: 2, smile: 1, surprised: 3, sad: 4, angry: 5, neutral: 0 }.freeze

      def initialize(ble_client)
        @session = AppleFoundationModel::Session.new(instructions: PERSONA)
        @client  = ble_client
      end

      # context: optional Hash of { last_face:, last_say:, last_action:,
      # last_action_at: Time, touch_zone:, touch_zone_label: }. The non-nil
      # entries are folded into a "situation" preamble so the model has
      # something to ground its reply on instead of falling back to "はい".
      def respond(prompt, context: nil)
        situation = build_situation(context)
        full_prompt = situation.empty? ? prompt : "#{situation}\n\n問いかけ: #{prompt}"
        reply = @session.respond(to: full_prompt)
        frame = FrameText.build(face_index: EMOTION_FACE[:smile], text: reply)
        @client.raw_send(frame)
        reply
      rescue AppleFoundationModel::GenerationError
        @client.raw_send(FrameText.build(face_index: EMOTION_FACE[:sad], text: "うまく考えられませんでした"))
        nil
      end

      def close
        @session.close
      end

      private

      def build_situation(context)
        return "" unless context.is_a?(Hash) && !context.empty?
        parts = []
        parts << "今の表情: #{context[:last_face]}"            if context[:last_face]
        parts << "自分が直前に言ったこと: 「#{context[:last_say]}」" if context[:last_say]
        parts << "直前に相手から聞いた話: 「#{context[:last_heard]}」" if context[:last_heard]
        if context[:last_action] && context[:last_action_at]
          elapsed = (Time.now - context[:last_action_at]).to_i
          parts << "#{elapsed}秒前に「#{context[:last_action]}」をした"
        end
        if context[:touch_zone_label]
          parts << "今、#{context[:touch_zone_label]}を触られた"
        elsif context[:touch_zone]
          parts << "今、頭の zone=#{context[:touch_zone]} を触られた"
        end
        return "" if parts.empty?
        "今の状況:\n- " + parts.join("\n- ")
      end
    end
  end
end
