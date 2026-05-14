require "test_helper"
require "stackchan_protocol/frame_parser"

class FrameParserBasicTest < Test::Unit::TestCase
  def test_decodes_single_frame
    p = StackchanProtocol::FrameParser.new
    frames = p.feed("<F:1>")
    assert_equal [{ "F" => "1" }], frames
  end

  def test_decodes_multi_pair_frame
    p = StackchanProtocol::FrameParser.new
    frames = p.feed("<L:1,R:255,G:0,B:0,M:p>")
    assert_equal [{ "L" => "1", "R" => "255", "G" => "0", "B" => "0", "M" => "p" }], frames
  end

  def test_strips_trailing_newline
    p = StackchanProtocol::FrameParser.new
    frames = p.feed("<F:1>\n")
    assert_equal [{ "F" => "1" }], frames
  end

  def test_returns_empty_for_no_frame
    p = StackchanProtocol::FrameParser.new
    assert_equal [], p.feed("garbage")
  end
end

class FrameParserPartialTest < Test::Unit::TestCase
  def test_holds_partial_frame_until_close_arrives
    p = StackchanProtocol::FrameParser.new
    assert_equal [], p.feed("<F:")
    assert_equal [{ "F" => "1" }], p.feed("1>")
  end

  def test_handles_multiple_chunks_for_one_frame
    p = StackchanProtocol::FrameParser.new
    p.feed("<L:1,")
    p.feed("R:0,")
    frames = p.feed("G:255,B:0,M:s>")
    assert_equal [{ "L" => "1", "R" => "0", "G" => "255", "B" => "0", "M" => "s" }], frames
  end
end

class FrameParserMultiTest < Test::Unit::TestCase
  def test_decodes_multiple_frames_in_one_chunk
    p = StackchanProtocol::FrameParser.new
    frames = p.feed("<F:1><F:2>")
    assert_equal [{ "F" => "1" }, { "F" => "2" }], frames
  end

  def test_garbage_between_frames_skipped
    p = StackchanProtocol::FrameParser.new
    frames = p.feed("zzzz<F:1>asdf<F:2>qwerty")
    assert_equal [{ "F" => "1" }, { "F" => "2" }], frames
  end
end

class FrameParserErrorTest < Test::Unit::TestCase
  def test_empty_frame_increments_error_count
    p = StackchanProtocol::FrameParser.new
    p.feed("<>")
    assert_equal 1, p.parse_error_count
  end

  def test_no_colon_in_pair_skipped
    p = StackchanProtocol::FrameParser.new
    frames = p.feed("<XYZ>")
    # XYZ has no colon -> skipped pair -> empty hash -> nil decoded -> error
    assert_equal 1, p.parse_error_count
    assert_equal [], frames
  end

  def test_bad_pair_among_good_pairs_keeps_good
    p = StackchanProtocol::FrameParser.new
    frames = p.feed("<F:1,bogus,L:1>")
    assert_equal [{ "F" => "1", "L" => "1" }], frames
  end
end

class FrameParserBufferOverflowTest < Test::Unit::TestCase
  def test_buffer_truncated_at_4096
    p = StackchanProtocol::FrameParser.new
    big = "X" * 5000
    p.feed(big)
    # The buffer should be trimmed; subsequent valid frame should still parse.
    frames = p.feed("<F:1>")
    assert_equal [{ "F" => "1" }], frames
  end
end
