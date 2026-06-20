require "foundation_model_mac"
require_relative "frame_text"

module Stackchan
  module AI
    # AI companion: prompts an Apple Foundation Model session and pushes the
    # reply to the device as a single <F:n,text:...> frame. Receives an
    # already-connected Stackchan::BLE::Client (daemon owns the connection).
    class Companion
      PERSONA = "あなたは小さな卓上ロボットです。返事は日本語で1文だけ、" \
                "20文字以内で短く答えてください。"
      EMOTION_FACE = { joy: 2, smile: 1, surprised: 3, sad: 4, angry: 5, neutral: 0 }.freeze

      def initialize(ble_client)
        @session = AppleFoundationModel::Session.new(instructions: PERSONA)
        @client  = ble_client
      end

      def respond(prompt)
        reply = @session.respond(to: prompt)
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
    end
  end
end
