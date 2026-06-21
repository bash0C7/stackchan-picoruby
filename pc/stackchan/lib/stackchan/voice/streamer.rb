# frozen_string_literal: true

module Stackchan::Voice
  # Streams a mu-law clip to the device over the existing NUS RX characteristic.
  #
  # Two modes:
  #   stream             - legacy immediate blast (no handshake, for non-Phase1 use)
  #   stream_halfduplex  - Phase1 half-duplex protocol with timing-based sync
  #
  # Half-duplex wire contract (device: AudioReceiver in app/application.rb):
  #   1. <A:N>\n          PC -> device: announce N-byte clip
  #   2. sleep READY_WAIT_S  PC: wait for device heartbeat to fire (~1s tick)
  #   3. blast N bytes    PC -> device: raw mu-law (btstack accumulates, main_task sleeps)
  #   4. sleep T+margin   PC: wait for device to drain+play+notify <A:done>
  class Streamer
    DEFAULT_CHUNK = 180
    READY_WAIT_S  = 1.5   # Time for device heartbeat to pick up <A:N> and enter receive mode.

    def initialize(client)
      @client = client
    end

    # Legacy: send <A:N> then immediately blast. Used by existing callers until replaced.
    def stream(ulaw_bytes)
      @client.write_without_ack("<A:#{ulaw_bytes.bytesize}>\n")
      chunk_size = negotiated_chunk
      self.class.chunks(ulaw_bytes, chunk_size).each do |c|
        @client.write_without_ack(c)
      end
      ulaw_bytes.bytesize
    end

    # Phase1 half-duplex: announce -> wait for device receive mode -> blast -> wait for playback.
    # sleep_fn injectable for testing (defaults to Kernel#sleep).
    def stream_halfduplex(ulaw_bytes, sleep_fn: nil)
      sleep_fn ||= method(:sleep)
      n = ulaw_bytes.bytesize
      @client.write_without_ack("<A:#{n}>\n")
      sleep_fn.call(READY_WAIT_S)
      chunk_size = negotiated_chunk
      self.class.chunks(ulaw_bytes, chunk_size).each do |c|
        @client.write_without_ack(c)
      end
      # Device T = n*1000/8000 + 500ms; add play time (n/8000s) and notify margin.
      sleep_fn.call(n / 8000.0 + 0.5 + 1.5)
      n
    end

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
