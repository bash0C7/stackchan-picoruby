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
  # All writes go through StackchanBleClient::Client#write_without_ack, whose
  # underlying CoreBluetooth path is now flow-controlled (waits on
  # canSendWriteWithoutResponse) — so this loop applies natural backpressure and
  # does not silently drop packets even though it never waits for an ACK.
  class Streamer
    DEFAULT_CHUNK = 180   # fallback if the negotiated MTU is unavailable.

    def initialize(client)
      @client = client
    end

    # Send one mu-law clip. Returns the number of audio bytes streamed.
    def stream(ulaw_bytes)
      @client.write_without_ack("<A:#{ulaw_bytes.bytesize}>\n")
      chunk_size = negotiated_chunk
      self.class.chunks(ulaw_bytes, chunk_size).each do |c|
        @client.write_without_ack(c)
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
      n = @client.max_write_chunk
      n && n > 0 ? n : DEFAULT_CHUNK
    rescue StandardError
      DEFAULT_CHUNK
    end
  end
end
