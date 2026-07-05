# frozen_string_literal: true

require_relative "test_helper"
require "stackchan/voice/ulaw"

class UlawTest < Test::Unit::TestCase
  U = Stackchan::Voice::Ulaw

  def test_silence_encodes_to_0xff_and_round_trips_to_zero
    assert_equal 0xFF, U.encode_sample(0)
    assert_equal 0, U.decode_sample(0xFF)
  end

  def test_round_trip_preserves_sign
    [-32000, -8000, -1000, -100, -1, 1, 100, 1000, 8000, 32000].each do |s|
      d = U.decode_sample(U.encode_sample(s))
      assert_operator (s <=> 0) * (d <=> 0), :>=, 0,
                      "sign flipped: #{s} -> #{d}"
    end
  end

  def test_round_trip_error_is_bounded_by_mu_law_quantization
    # mu-law has ~4-bit mantissa -> relative error ~1/16, plus the BIAS step.
    s = -32635
    while s <= 32635
      d = U.decode_sample(U.encode_sample(s))
      bound = (s.abs / 16) + 132
      assert_operator (d - s).abs, :<=, bound, "sample #{s} -> #{d} exceeds #{bound}"
      s += 137
    end
  end

  def test_decode_matches_device_algorithm_for_all_codes
    # Mirror app/application.rb Speaker.ulaw_byte_to_linear exactly so encode
    # here round-trips against the device decoder.
    bias = 0x84
    (0..255).each do |byte|
      u = (~byte) & 0xFF
      t = ((u & 0x0F) << 3) + bias
      t <<= ((u & 0x70) >> 4)
      expected = (u & 0x80) != 0 ? (bias - t) : (t - bias)
      assert_equal expected, U.decode_sample(byte), "code 0x#{byte.to_s(16)}"
    end
  end

  def test_encode_pcm_length_is_one_byte_per_sample
    pcm = [0, 1000, -1000, 32000].pack("s<*")  # 4 samples, 8 bytes
    ulaw = U.encode_pcm(pcm)
    assert_equal 4, ulaw.bytesize
  end

  def test_gain_reduces_magnitude
    pcm = [20000].pack("s<*")
    loud = U.decode_sample(U.encode_pcm(pcm, gain: 1.0).getbyte(0)).abs
    soft = U.decode_sample(U.encode_pcm(pcm, gain: 0.25).getbyte(0)).abs
    assert_operator soft, :<, loud
  end
end
