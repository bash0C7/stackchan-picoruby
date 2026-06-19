# frozen_string_literal: true

require_relative "test_helper"

class WavTest < Test::Unit::TestCase
  W = StackchanVoice::Wav

  # Build a minimal 8 kHz mono PCM16 WAV around `pcm`.
  def build_wav(pcm, rate: 8000, channels: 1, bits: 16, audio_format: 1)
    byte_rate   = rate * channels * bits / 8
    block_align = channels * bits / 8
    fmt = [audio_format, channels, rate, byte_rate, block_align, bits].pack("vvVVvv")
    data_sz = pcm.bytesize
    riff_sz = 4 + (8 + fmt.bytesize) + (8 + data_sz)
    out = +"RIFF"
    out << [riff_sz].pack("V") << "WAVE"
    out << "fmt " << [fmt.bytesize].pack("V") << fmt
    out << "data" << [data_sz].pack("V") << pcm
    out
  end

  def test_parses_data_and_format
    pcm = [0, 100, -100].pack("s<*")
    fmt, data = W.parse(build_wav(pcm))
    assert_equal 1, fmt.audio_format
    assert_equal 1, fmt.channels
    assert_equal 8000, fmt.sample_rate
    assert_equal 16, fmt.bits_per_sample
    assert_equal pcm, data
  end

  def test_skips_unknown_chunks_before_data
    pcm = [42].pack("s<*")
    wav = build_wav(pcm)
    # Inject a LIST chunk after fmt (afconvert sometimes emits extra chunks).
    insert_at = wav.index("data")
    list = "LIST" + [4].pack("V") + "INFO"
    wav = wav.byteslice(0, insert_at) + list + wav.byteslice(insert_at..-1)
    _fmt, data = W.parse(wav)
    assert_equal pcm, data
  end

  def test_expect_8k_mono_s16_passes_and_rejects
    ok = W.parse(build_wav([1].pack("s<*"))).first
    assert_equal ok, W.expect_8k_mono_s16!(ok)

    bad = W.parse(build_wav([1].pack("s<*"), rate: 16000)).first
    assert_raise(W::FormatError) { W.expect_8k_mono_s16!(bad) }
  end

  def test_rejects_non_riff
    assert_raise(W::FormatError) { W.parse("not a wav file at all") }
  end
end
