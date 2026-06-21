# frozen_string_literal: true

module Stackchan::Voice
  # Streams a mu-law clip to the device over the existing NUS RX characteristic.
  #
  # Wire contract (device side: app/application.rb StackChanApp audio receive):
  #   1. a standalone control frame  <A:nbytes>\n  announces the clip length;
  #   2. then `nbytes` of raw mu-law in writes of up to the negotiated MTU.
  # The device switches to "audio receive" mode on the control frame, counts raw
  # bytes (bypassing the frame parser) until nbytes, decodes, and plays. The
  # control frame MUST be its own write so no audio bytes straddle the boundary.
  #
  # Audio writes go through StackchanBleClient::Client#write_without_ack with
  # response: true (ATT Write With Response). Each chunk waits for the device's
  # auto-sent ATT Write Response, which (a) lets us use the full negotiated MTU
  # (≈509 B vs macOS's ~182 B Write-Without-Response cap) so the device receives
  # ~3x fewer GATT writes, and (b) paces the device's BLE task one write at a
  # time. No device-app ACK frame is exchanged for audio.
  class Streamer
    DEFAULT_CHUNK = 180   # fallback if the negotiated MTU is unavailable.

    def initialize(client)
      @client = client
    end

    # Send one mu-law clip. Returns the number of audio bytes streamed.
    def stream(ulaw_bytes)
      @client.write_without_ack("<A:#{ulaw_bytes.bytesize}>\n", response: true)
      chunk_size = negotiated_chunk
      self.class.chunks(ulaw_bytes, chunk_size).each do |c|
        @client.write_without_ack(c, response: true)
      end
      ulaw_bytes.bytesize
    end

    # Pure helper: split a byte string into <= size byteslices (testable).
    def self.chunks(bytes, size)
      size = DEFAULT_CHUNK if size.nil? || size <= 0
      out = []
      i = 0
      total = bytes.bytesize
      while i < total
        out << bytes.byteslice(i, size)
        i += size
      end
      out
    end

    private

    def negotiated_chunk
      n = @client.max_write_chunk(response: true)
      n && n > 0 ? n : DEFAULT_CHUNK
    rescue StandardError
      DEFAULT_CHUNK
    end
  end
end
