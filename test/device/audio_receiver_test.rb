class AudioReceiverTest < Picotest::Test
  class FakeParser
    def initialize(*responses)
      @responses = responses
    end

    def feed(_data)
      @responses.empty? ? [] : @responses.shift
    end
  end

  def make_speaker
    Speaker.new(i2c: FakeI2C.new, i2s: I2S.new(sample_rate: 8000))
  end

  def test_audio_frame_sends_ready_sleeps_drains_plays
    spk = make_speaker
    notifies = []
    delays = []
    drain_queue = ["\x01\x02\x03\x04\x05\x06"]

    rx = StackchanApp::AudioReceiver.new(
      speaker: spk,
      parser: FakeParser.new([{"A" => "6"}]),
      delay_fn: ->(ms) { delays << ms }
    )
    done = rx.consume(
      "<A:6>\n",
      notify_fn: ->(msg) { notifies << msg },
      drain_fn:  -> { drain_queue.shift }
    )

    assert_equal 1, done
    assert_equal ["<A:ready>\n"], notifies
    assert_equal [500], delays
    assert_equal 3212, spk.i2s.written.bytesize
  end

  def test_t_ms_scales_with_byte_count
    delays = []
    drain_queue = []

    rx = StackchanApp::AudioReceiver.new(
      speaker: make_speaker,
      parser: FakeParser.new([{"A" => "8000"}]),
      delay_fn: ->(ms) { delays << ms }
    )
    rx.consume(
      "<A:8000>\n",
      notify_fn: ->(msg) {},
      drain_fn:  -> { drain_queue.shift }
    )

    assert_equal [1500], delays
  end

  def test_played_clip_decodes_ulaw_correctly
    spk = make_speaker
    drain_queue = ["\x10\x20\x30"]

    rx = StackchanApp::AudioReceiver.new(
      speaker: spk,
      parser: FakeParser.new([{"A" => "3"}]),
      delay_fn: ->(ms) {}
    )
    rx.consume(
      "<A:3>\n",
      notify_fn: ->(msg) {},
      drain_fn:  -> { drain_queue.shift }
    )

    expected = Speaker.ulaw_decode("\x10\x20\x30")
    assert_equal expected, spk.i2s.written.byteslice(0, 6)
  end

  def test_non_audio_frames_yielded_to_block
    rx = StackchanApp::AudioReceiver.new(
      speaker: make_speaker,
      parser: FakeParser.new([{"F" => "1"}, {"text" => "hi"}])
    )
    frames = []
    done = rx.consume(
      "<F:1,text:hi>\n",
      notify_fn: ->(msg) {},
      drain_fn:  -> { nil }
    ) { |f| frames << f }

    assert_equal 0, done
    assert_equal 2, frames.length
    assert_equal "1", frames[0]["F"]
  end

  def test_no_speaker_skips_audio
    delays = []

    rx = StackchanApp::AudioReceiver.new(
      speaker: nil,
      parser: FakeParser.new([{"A" => "6"}]),
      delay_fn: ->(ms) { delays << ms }
    )
    done = rx.consume(
      "<A:6>\n",
      notify_fn: ->(msg) {},
      drain_fn:  -> { nil }
    )

    assert_equal 0, done
    assert_equal 0, delays.length
  end

  def test_zero_length_audio_ignored
    delays = []

    rx = StackchanApp::AudioReceiver.new(
      speaker: make_speaker,
      parser: FakeParser.new([{"A" => "0"}]),
      delay_fn: ->(ms) { delays << ms }
    )
    done = rx.consume(
      "<A:0>\n",
      notify_fn: ->(msg) {},
      drain_fn:  -> { nil }
    )

    assert_equal 0, done
    assert_equal 0, delays.length
  end

  def test_drain_multiple_chunks_concatenated
    spk = make_speaker
    drain_queue = ["\x01\x02\x03", "\x04\x05\x06"]

    rx = StackchanApp::AudioReceiver.new(
      speaker: spk,
      parser: FakeParser.new([{"A" => "6"}]),
      delay_fn: ->(ms) {}
    )
    rx.consume(
      "<A:6>\n",
      notify_fn: ->(msg) {},
      drain_fn:  -> { drain_queue.shift }
    )

    assert_equal 3212, spk.i2s.written.bytesize
  end
end
