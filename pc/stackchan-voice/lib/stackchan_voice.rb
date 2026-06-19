# frozen_string_literal: true

require_relative "stackchan_voice/ulaw"
require_relative "stackchan_voice/wav"
require_relative "stackchan_voice/tts"
require_relative "stackchan_voice/streamer"

module StackchanVoice
  # Orchestrates: text -> mu-law (Tts) -> BLE stream (Streamer) over a connected
  # StackchanBleClient::Client. The robot speaks with its own voice (Phase 4).
  class Voice
    def initialize(client:, tts: Tts.new)
      @client   = client
      @tts      = tts
      @streamer = Streamer.new(client)
    end

    # Synthesize `text` and stream it to the device. Returns mu-law byte count.
    def speak(text)
      ulaw = @tts.synthesize(text)
      @streamer.stream(ulaw)
    end
  end
end
