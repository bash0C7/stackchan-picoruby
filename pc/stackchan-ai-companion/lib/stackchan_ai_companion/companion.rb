require "foundation_model_mac"
require "stackchan_ble_client"
require_relative "frame_text"

module StackchanAiCompanion
  # Phase 0: Mac -> device one-way. Read a prompt, ask the Foundation Model,
  # map a coarse emotion to a face index, push one <F:n,text:...> frame.
  class Companion
    PERSONA = "あなたは小さな卓上ロボットです。返事は日本語で1文だけ、" \
              "20文字以内で短く答えてください。"
    # Coarse keyword -> face index (F:0..5 = Neutral/Smile/Joy/Surprised/Sad/Angry),
    # mirroring the device FACE_TABLE. Phase 0 is one-way and uses only :smile
    # (reply) and :sad (FM error); classifying the reply's emotion is a later
    # phase, so the remaining keys are intentionally unused for now.
    EMOTION_FACE = { joy: 2, smile: 1, surprised: 3, sad: 4, angry: 5, neutral: 0 }.freeze

    def initialize(device_name: ENV.fetch("BLE_DEVICE_NAME", "StackChan-PicoRuby"),
                   name_prefix: "StackChan")
      @session = AppleFoundationModel::Session.new(instructions: PERSONA)
      @client  = StackchanBleClient::Client.new(device_name: device_name, name_prefix: name_prefix)
    end

    def connect
      @client.connect
      self
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
      @client.disconnect
      @session.close
    end
  end
end
