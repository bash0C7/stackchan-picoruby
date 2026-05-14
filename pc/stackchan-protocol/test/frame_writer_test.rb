require "test_helper"
require "stackchan_protocol/frame_writer"

class FrameWriterTest < Test::Unit::TestCase
  def test_simple_face
    assert_equal "<F:1>\n", StackchanProtocol::FrameWriter.encode(F: "1")
  end

  def test_led_with_rgb_and_mode
    encoded = StackchanProtocol::FrameWriter.encode(L: "1", R: 255, G: 0, B: 0, M: "s")
    assert_equal "<L:1,R:255,G:0,B:0,M:s>\n", encoded
  end

  def test_combined_face_and_led
    encoded = StackchanProtocol::FrameWriter.encode(F: "1", L: "1", R: 0, G: 255, B: 0, M: "s")
    assert_equal "<F:1,L:1,R:0,G:255,B:0,M:s>\n", encoded
  end

  def test_off_only
    encoded = StackchanProtocol::FrameWriter.encode(L: "1", M: "o")
    assert_equal "<L:1,M:o>\n", encoded
  end

  def test_integer_values_stringified
    encoded = StackchanProtocol::FrameWriter.encode(R: 42)
    assert_equal "<R:42>\n", encoded
  end

  def test_symbol_keys_become_strings
    encoded = StackchanProtocol::FrameWriter.encode(F: "1")
    assert_match(/F:1/, encoded)
  end
end
