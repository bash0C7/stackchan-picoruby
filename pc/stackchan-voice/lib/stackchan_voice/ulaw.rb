# frozen_string_literal: true

module StackchanVoice
  # ITU-T G.711 mu-law codec (encoder for Mac->device; decoder kept for tests).
  # The device decodes with the identical algorithm (app/application.rb
  # Speaker.ulaw_byte_to_linear), so encode here must round-trip against it.
  module Ulaw
    BIAS = 0x84      # 132
    CLIP = 32635

    # Segment (exponent) lookup: index = (magnitude+BIAS) >> 7, 0..255.
    # Standard mu-law segment boundaries (1,2,4,8,16,32,64,128).
    EXP_LUT = (0..255).map do |i|
      if    i < 2   then 0
      elsif i < 4   then 1
      elsif i < 8   then 2
      elsif i < 16  then 3
      elsif i < 32  then 4
      elsif i < 64  then 5
      elsif i < 128 then 6
      else               7
      end
    end.freeze

    # signed 16-bit linear PCM sample -> 8-bit mu-law code.
    def self.encode_sample(sample)
      sample = -32768 if sample < -32768
      sample = 32767 if sample > 32767
      sign = sample < 0 ? 0x80 : 0x00
      mag = sample < 0 ? -sample : sample
      mag = CLIP if mag > CLIP
      mag += BIAS
      exponent = EXP_LUT[(mag >> 7) & 0xFF]
      mantissa = (mag >> (exponent + 3)) & 0x0F
      (~(sign | (exponent << 4) | mantissa)) & 0xFF
    end

    # 8-bit mu-law code -> signed 16-bit linear (mirror of the device decoder).
    def self.decode_sample(byte)
      u = (~byte) & 0xFF
      t = ((u & 0x0F) << 3) + BIAS
      t <<= ((u & 0x70) >> 4)
      (u & 0x80) != 0 ? (BIAS - t) : (t - BIAS)
    end

    # Encode a little-endian signed-16 PCM byte string to a mu-law byte string.
    # `gain` (0.0..1.0) scales amplitude before encoding — the loudness knob
    # (Spike A HITL: full-scale is too loud on the 1W speaker).
    def self.encode_pcm(pcm_le16, gain: 1.0)
      out = +""
      n = pcm_le16.bytesize / 2
      i = 0
      while i < n
        lo = pcm_le16.getbyte(2 * i)
        hi = pcm_le16.getbyte(2 * i + 1)
        s = lo | (hi << 8)
        s -= 0x10000 if s >= 0x8000   # to signed
        s = (s * gain).to_i unless gain == 1.0
        out << encode_sample(s).chr
        i += 1
      end
      out
    end
  end
end
