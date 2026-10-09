# frozen_string_literal: true

module Stackchan
  module Voice
    module Ulaw
      BIAS = 0x84
      CLIP = 32635

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

      def self.encode_pcm(pcm_le16, gain: 1.0)
        out = +""
        n = pcm_le16.bytesize / 2
        i = 0
        while i < n
          lo = pcm_le16.getbyte(2 * i)
          hi = pcm_le16.getbyte(2 * i + 1)
          s = lo | (hi << 8)
          s -= 0x10000 if s >= 0x8000
          s = (s * gain).to_i unless gain == 1.0
          out << encode_sample(s).chr
          i += 1
        end
        out
      end
    end
  end
end
