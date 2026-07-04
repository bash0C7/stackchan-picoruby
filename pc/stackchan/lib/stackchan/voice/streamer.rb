# frozen_string_literal: true

require_relative "../ble"

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
  #   4. await <A:done>   PC: block on the device's own drain+play completion
  #                        notification (NOT a fixed sleep -- decode+playback
  #                        time doesn't scale predictably with clip length).
  class Streamer
    DEFAULT_CHUNK = 180
    READY_WAIT_S  = 1.5   # Time for device heartbeat to pick up <A:N> and enter receive mode.
    AUDIO_DONE_TIMEOUT_S = 30.0  # safety net if the device's <A:done> notify is somehow lost

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
      await_audio_done
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

    # Wait for the device's <A:done> half-duplex-audio completion notification
    # (app/application.rb's StackChanApp#consume_rx writes this only after
    # AudioReceiver#consume fully returns -- i.e. after both the T-ms pre-play
    # delay AND the actual mu-law decode + I2S playback + silence-tail write
    # have all finished). This replaces a fixed-sleep estimate: real-hardware
    # repro (pc/stackchan-pico, the PicoRuby port of this same protocol)
    # showed the device's interpreted-Ruby mu-law decode doesn't scale simply
    # with "clip length / sample rate," so a formula-based sleep either
    # wastes time or times out the very next command's ACK for longer clips.
    # Discards any other frame (e.g. a stray <A:ready>) seen while waiting.
    def await_audio_done
      deadline = monotonic_now + AUDIO_DONE_TIMEOUT_S
      loop do
        remaining = deadline - monotonic_now
        raise Stackchan::BLE::TimeoutError, "<A:done> timeout" if remaining <= 0
        frame = @client.read_frame(timeout: remaining)
        raise Stackchan::BLE::TimeoutError, "<A:done> timeout" if frame.nil?
        return if frame.start_with?("<A:done>")
      end
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
