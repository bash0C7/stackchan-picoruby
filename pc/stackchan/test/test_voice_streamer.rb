# frozen_string_literal: true

require_relative "test_helper"
require "stackchan/voice"

class StreamerTest < Test::Unit::TestCase
  S = Stackchan::Voice::Streamer

  # Fake client recording the exact write sequence. read_frame serves queued
  # frames (defaults to an immediate "<A:done>\n" so callers that don't care
  # about the notification wait still get a realistic, non-hanging fake).
  class FakeClient
    attr_reader :writes

    def initialize(chunk:, frames: ["<A:done>\n"])
      @chunk = chunk
      @writes = []
      @frames = frames.dup
    end

    def max_write_chunk
      @chunk
    end

    def write_without_ack(payload)
      @writes << payload
    end

    def read_frame(timeout: nil)
      @frames.shift
    end
  end

  def test_chunks_splits_to_size_with_remainder
    bytes = "abcdefg"   # 7 bytes
    assert_equal %w[abc def g], S.chunks(bytes, 3)
  end

  def test_chunks_falls_back_on_nonpositive_size
    bytes = "x" * 200
    cs = S.chunks(bytes, 0)
    assert_equal S::DEFAULT_CHUNK, cs.first.bytesize
  end

  def test_stream_sends_control_frame_then_chunked_audio
    ulaw = "\x10\x20\x30\x40\x50"  # 5 bytes
    client = FakeClient.new(chunk: 2)
    n = S.new(client).stream(ulaw)

    assert_equal 5, n
    assert_equal "<A:5>\n", client.writes.first
    # control frame is its own write; audio follows in chunk-sized writes.
    assert_equal ["<A:5>\n", "\x10\x20", "\x30\x40", "\x50"], client.writes
  end

  def test_control_frame_byte_count_matches_audio_total
    ulaw = "z" * 1000
    client = FakeClient.new(chunk: 180)
    S.new(client).stream(ulaw)
    assert_equal "<A:1000>\n", client.writes.first
    audio = client.writes[1..].join
    assert_equal ulaw, audio
    assert_equal 1000, audio.bytesize
  end

  def test_stream_halfduplex_sends_control_then_blast_then_waits_for_done
    ulaw = "\x10\x20\x30\x40\x50"  # 5 bytes
    client = FakeClient.new(chunk: 2)
    sleeps = []
    n = S.new(client).stream_halfduplex(ulaw, sleep_fn: ->(t) { sleeps << t })

    assert_equal 5, n
    assert_equal "<A:5>\n", client.writes[0]
    assert_equal ["\x10\x20", "\x30\x40", "\x50"], client.writes[1..]
    assert_equal 1, sleeps.length
    assert_equal S::READY_WAIT_S, sleeps[0]
  end

  def test_stream_halfduplex_discards_frames_before_a_done
    ulaw = "\x10\x20\x30\x40\x50"  # 5 bytes
    client = FakeClient.new(chunk: 2, frames: ["<A:ready>\n", ".\n", "<A:done>\n"])
    S.new(client).stream_halfduplex(ulaw, sleep_fn: ->(*) {})
    # no error raised means it kept reading past the non-matching frames
    assert_true true
  end

  def test_stream_halfduplex_raises_timeout_if_a_done_never_arrives
    ulaw = "\x10\x20\x30\x40\x50"  # 5 bytes
    client = FakeClient.new(chunk: 2, frames: [])
    assert_raise(Stackchan::BLE::TimeoutError) do
      S.new(client).stream_halfduplex(ulaw, sleep_fn: ->(*) {})
    end
  end
end
