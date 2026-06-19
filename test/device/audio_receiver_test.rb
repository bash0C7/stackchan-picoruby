class AudioReceiverTest < Picotest::Test
  # Minimal frame parser: returns a scripted frame list per feed() call.
  # AudioReceiver only calls feed() in frame mode (never while accumulating
  # audio), so one scripted response per non-audio consume() call is enough.
  class FakeParser
    def initialize(*responses)
      @responses = responses
    end

    def feed(_data)
      @responses.empty? ? [] : @responses.shift
    end
  end

  def make_speaker
    # Real Speaker over host fakes (FakeI2C + FakeI2S via harness load_files),
    # so the test exercises the real mu-law decode + I2S write path.
    Speaker.new(i2c: FakeI2C.new, i2s: I2S.new(sample_rate: 8000))
  end

  def receiver(speaker, *parser_responses)
    StackchanApp::AudioReceiver.new(speaker: speaker, parser: FakeParser.new(*parser_responses))
  end

  def test_control_frame_enters_audio_mode_without_yielding
    rx = receiver(make_speaker, [{ "A" => "6" }])
    frames = []
    done = rx.consume("<A:6>\n") { |f| frames << f }
    assert_equal 0, done
    assert rx.receiving?
    assert_equal 0, frames.length
  end

  def test_accumulates_across_chunks_then_plays_exact_bytes
    spk = make_speaker
    rx = receiver(spk, [{ "A" => "6" }])
    rx.consume("<A:6>\n") { |_f| }          # enter audio mode (6 bytes)
    d1 = rx.consume("\x01\x02\x03") { |_f| } # 3/6
    assert_equal 0, d1
    assert rx.receiving?
    d2 = rx.consume("\x04\x05\x06") { |_f| } # 6/6 -> play
    assert_equal 1, d2
    assert_false rx.receiving?
    # 6 mu-law bytes -> 12 PCM bytes, plus the 800-byte silence tail.
    assert_equal 812, spk.i2s.written.bytesize
  end

  def test_played_clip_matches_decoded_ulaw
    spk = make_speaker
    rx = receiver(spk, [{ "A" => "3" }])
    rx.consume("<A:3>\n") { |_f| }
    rx.consume("\x10\x20\x30") { |_f| }
    expected = Speaker.ulaw_decode("\x10\x20\x30")  # 6 PCM bytes
    assert_equal expected, spk.i2s.written.byteslice(0, 6)
  end

  def test_non_audio_frames_routed_to_block
    rx = receiver(make_speaker, [{ "F" => "1" }, { "text" => "hi" }])
    frames = []
    done = rx.consume("<F:1,text:hi>\n") { |f| frames << f }
    assert_equal 0, done
    assert_equal 2, frames.length
    assert_equal "1", frames[0]["F"]
    assert_false rx.receiving?
  end

  def test_trailing_bytes_after_completion_are_routed_as_frames
    spk = make_speaker
    # feed #1: control frame; feed #2: the trailing frame after the 4 audio bytes.
    rx = receiver(spk, [{ "A" => "4" }], [{ "F" => "2" }])
    rx.consume("<A:4>\n") { |_f| }
    frames = []
    done = rx.consume("\x01\x02\x03\x04XXXXX") { |f| frames << f }
    assert_equal 1, done
    assert_equal 1, frames.length
    assert_equal "2", frames[0]["F"]
    assert_false rx.receiving?
  end

  def test_no_speaker_ignores_audio_frame
    rx = receiver(nil, [{ "A" => "6" }])
    rx.consume("<A:6>\n") { |_f| }
    assert_false rx.receiving?
  end

  def test_zero_length_audio_frame_is_ignored
    rx = receiver(make_speaker, [{ "A" => "0" }])
    rx.consume("<A:0>\n") { |_f| }
    assert_false rx.receiving?
  end
end
