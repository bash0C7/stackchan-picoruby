class SidecarVoiceTest < Picotest::Test
  def wav(pcm, rate: 8000, channels: 1, bits: 16, extra: "")
    fmt = [1, channels, rate, rate * channels * bits / 8, channels * bits / 8, bits].pack("vvVVvv")
    body = "WAVE" + "fmt " + [fmt.bytesize].pack("V") + fmt + extra + "data" + [pcm.bytesize].pack("V") + pcm
    "RIFF" + [body.bytesize].pack("V") + body
  end

  def device_decode(byte)
    u = (~byte) & 0xFF
    t = ((u & 0x0F) << 3) + StackchanSidecar::Ulaw::BIAS
    t <<= ((u & 0x70) >> 4)
    (u & 0x80) != 0 ? (StackchanSidecar::Ulaw::BIAS - t) : (t - StackchanSidecar::Ulaw::BIAS)
  end

  def test_parse_reads_the_format_and_the_samples
    pcm = [0, 100, -100].pack("s<*")
    fmt, data = StackchanSidecar::Wav.parse(wav(pcm))
    assert_equal({ audio_format: 1, channels: 1, sample_rate: 8000, bits: 16 }, fmt)
    assert_equal pcm, data
  end

  def test_parse_skips_chunks_before_the_data
    pcm = [42].pack("s<*")
    filler = "FLLR" + [5].pack("V") + "\0" * 6
    assert_equal pcm, StackchanSidecar::Wav.mono_s16(wav(pcm, extra: filler))
  end

  def test_mono_s16_rejects_another_rate_or_layout
    pcm = [1].pack("s<*")
    [wav(pcm, rate: 4000), wav(pcm, channels: 2), wav(pcm, bits: 8)].each do |bytes|
      assert_raise(StackchanSidecar::Wav::FormatError) { StackchanSidecar::Wav.mono_s16(bytes) }
    end
  end

  def test_a_truncated_wav_is_a_format_error
    bytes = wav([1, 2, 3, 4].pack("s<*"))
    [bytes.byteslice(0, bytes.bytesize - 3), bytes.byteslice(0, 30)].each do |cut|
      assert_raise(StackchanSidecar::Wav::FormatError) { StackchanSidecar::Wav.parse(cut) }
    end
  end

  def test_parse_rejects_what_is_not_riff
    assert_raise(StackchanSidecar::Wav::FormatError) { StackchanSidecar::Wav.parse("not a wav file at all") }
  end

  def test_silence_encodes_to_0xff
    assert_equal 0xFF, StackchanSidecar::Ulaw.encode_sample(0)
    assert_equal 0, device_decode(0xFF)
  end

  def test_the_device_decoder_keeps_the_sign_and_a_bounded_error
    s = -32635
    while s <= 32635
      d = device_decode(StackchanSidecar::Ulaw.encode_sample(s))
      assert (s <=> 0) * (d <=> 0) >= 0
      assert (d - s).abs <= (s.abs / 16) + 132
      s += 137
    end
  end

  def test_encode_pcm_writes_one_byte_per_sample_and_gain_softens
    pcm = [20000, 0, -20000, 32000].pack("s<*")
    assert_equal 4, StackchanSidecar::Ulaw.encode_pcm(pcm).bytesize
    loud = device_decode(StackchanSidecar::Ulaw.encode_pcm(pcm, 1.0).getbyte(0)).abs
    soft = device_decode(StackchanSidecar::Ulaw.encode_pcm(pcm, 0.25).getbyte(0)).abs
    assert soft < loud
  end
end
