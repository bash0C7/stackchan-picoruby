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
    AW88298.new(i2c: FakeI2C.new, i2s: I2S.new(sample_rate: 8000))
  end

  def receiver(speaker:, parser:, notify: ->(msg) {}, drain: -> { nil }, pump: -> {})
    StackchanApp::AudioReceiver.new(speaker: speaker, parser: parser, notify: notify, drain: drain, pump: pump)
  end

  def total_delay_ms
    total = 0
    Machine.delays.each { |ms| total += ms }
    total
  end

  def test_audio_frame_sends_ready_waits_3000_ms_in_steps_drains_and_plays_with_silence_tail
    spk = make_speaker
    notifies = []
    Machine.delays.clear
    drain_queue = ["\x01\x02\x03\x04\x05\x06"]

    rx = receiver(speaker: spk, parser: FakeParser.new([{"A" => "6"}]),
                  notify: ->(msg) { notifies << msg }, drain: -> { drain_queue.shift })
    done = rx.consume("<A:6>\n")

    assert_equal true, done
    assert_equal ["<A:ready>\n"], notifies
    assert_equal 3000, total_delay_ms
    assert_equal 3212, spk.i2s.written.bytesize
  end

  def test_wait_is_n_bytes_at_8000_per_second_plus_3000_ms
    Machine.delays.clear
    drain_queue = []

    rx = receiver(speaker: make_speaker, parser: FakeParser.new([{"A" => "8000"}]),
                  drain: -> { drain_queue.shift })
    rx.consume("<A:8000>\n")

    assert_equal 4000, total_delay_ms
  end

  def test_played_clip_decodes_ulaw_correctly
    spk = make_speaker
    drain_queue = ["\x10\x20\x30"]

    rx = receiver(speaker: spk, parser: FakeParser.new([{"A" => "3"}]),
                  drain: -> { drain_queue.shift })
    rx.consume("<A:3>\n")

    expected = AW88298.ulaw_decode("\x10\x20\x30")
    assert_equal expected, spk.i2s.written.byteslice(0, 6)
  end

  def test_non_audio_frames_yielded_to_block
    rx = receiver(speaker: make_speaker, parser: FakeParser.new([{"F" => "1"}, {"text" => "hi"}]))
    frames = []
    done = rx.consume("<F:1,text:hi>\n") { |f| frames << f }

    assert_equal false, done
    assert_equal 2, frames.length
    assert_equal "1", frames[0]["F"]
  end

  def test_no_speaker_still_readies_and_drains_the_blast_so_none_of_it_is_dispatched
    blast = "\x01<x:1>\x02<\x03"
    rx_queue = [blast]
    notifies = []
    dispatched = []

    rx = receiver(speaker: nil, parser: StackchanProtocol::FrameParser.new,
                  notify: ->(msg) { notifies << msg }, drain: -> { rx_queue.shift })
    done = rx.consume("<A:#{blast.bytesize}>\n") { |f| dispatched << f }
    while (data = rx_queue.shift)
      rx.consume(data) { |f| dispatched << f }
    end
    rx.consume("<F:1>\n") { |f| dispatched << f }

    assert_equal true, done
    assert_equal ["<A:ready>\n"], notifies
    assert_equal [{ "F" => "1" }], dispatched
  end

  def test_zero_length_audio_ignored
    Machine.delays.clear

    rx = receiver(speaker: make_speaker, parser: FakeParser.new([{"A" => "0"}]))
    done = rx.consume("<A:0>\n")

    assert_equal false, done
    assert_equal 0, Machine.delays.length
  end

  def test_wait_is_split_into_drain_steps_that_each_pump_the_port_and_take_what_arrived
    spk = make_speaker
    Machine.delays.clear
    pumps = 0
    arrivals = ["\x01\x02", "\x03\x04", "\x05\x06"]
    drained = []

    rx = receiver(speaker: spk, parser: FakeParser.new([{"A" => "6"}]),
                  drain: -> { drained.shift },
                  pump:  -> { pumps += 1; (a = arrivals.shift) && (drained << a) })
    rx.consume("<A:6>\n")

    assert_equal 3000, total_delay_ms
    longest = 0
    Machine.delays.each { |ms| longest = ms if ms > longest }
    assert_equal StackchanApp::AudioReceiver::DRAIN_STEP_MS, longest
    assert_equal Machine.delays.length, pumps
    assert_equal 3212, spk.i2s.written.bytesize
  end

  def test_drain_multiple_chunks_concatenated
    spk = make_speaker
    drain_queue = ["\x01\x02\x03", "\x04\x05\x06"]

    rx = receiver(speaker: spk, parser: FakeParser.new([{"A" => "6"}]),
                  drain: -> { drain_queue.shift })
    rx.consume("<A:6>\n")

    assert_equal 3212, spk.i2s.written.bytesize
  end
end
