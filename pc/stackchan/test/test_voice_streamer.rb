# frozen_string_literal: true

require_relative "test_helper"
require "stackchan/voice"

class StreamerTest < Test::Unit::TestCase
  S = Stackchan::Voice::Streamer

  # Fake client recording the exact write sequence and per-call response flags.
  class FakeClient
    attr_reader :writes, :chunk_response_flags, :write_response_flags
    def initialize(chunk:)
      @chunk = chunk
      @writes = []
      @chunk_response_flags = []
      @write_response_flags = []
    end

    def max_write_chunk(response: false)
      @chunk_response_flags << response
      @chunk
    end

    def write_without_ack(payload, response: false)
      @writes << payload
      @write_response_flags << response
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

  def test_stream_requests_with_response_mtu_for_chunk_size
    client = FakeClient.new(chunk: 180)
    S.new(client).stream("z" * 10)
    assert_equal [true], client.chunk_response_flags
  end

  def test_stream_writes_control_and_all_chunks_with_response_true
    client = FakeClient.new(chunk: 2)
    S.new(client).stream("\x10\x20\x30")  # control + 2 chunks = 3 writes
    assert_equal [true, true, true], client.write_response_flags
  end
end
