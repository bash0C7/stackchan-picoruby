# frozen_string_literal: true

require_relative "test_helper"
require "stackchan/voice"

class StreamerTest < Test::Unit::TestCase
  S = Stackchan::Voice::Streamer

  # Fake client recording the exact write sequence.
  class FakeClient
    attr_reader :writes
    def initialize(chunk:)
      @chunk = chunk
      @writes = []
    end

    def max_write_chunk
      @chunk
    end

    def write_without_ack(payload)
      @writes << payload
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

  def test_stream_halfduplex_sends_control_then_blast_with_two_sleeps
    ulaw = "\x10\x20\x30\x40\x50"  # 5 bytes
    client = FakeClient.new(chunk: 2)
    sleeps = []
    n = S.new(client).stream_halfduplex(ulaw, sleep_fn: ->(t) { sleeps << t })

    assert_equal 5, n
    assert_equal "<A:5>\n", client.writes[0]
    assert_equal ["\x10\x20", "\x30\x40", "\x50"], client.writes[1..]
    assert_equal 2, sleeps.length
    assert_equal S::READY_WAIT_S, sleeps[0]
    # post-blast sleep: 5/8000.0 + 0.5 + 1.5 = ~2.000625
    assert_true sleeps[1] >= 2.0
    assert_true sleeps[1] < 3.0
  end

  def test_stream_halfduplex_post_blast_sleep_scales_with_bytes
    ulaw = "x" * 8000
    client = FakeClient.new(chunk: 180)
    sleeps = []
    S.new(client).stream_halfduplex(ulaw, sleep_fn: ->(t) { sleeps << t })

    # post-blast: 8000/8000.0 + 0.5 + 1.5 = 3.0
    assert_equal 3.0, sleeps[1]
  end
end
