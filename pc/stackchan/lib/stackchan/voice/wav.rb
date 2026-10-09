# frozen_string_literal: true

module Stackchan
  module Voice
    module Wav
      SAMPLE_RATE = 8000

      Format = Struct.new(:audio_format, :channels, :sample_rate, :bits_per_sample)

      class FormatError < StandardError; end

      def self.parse(bytes)
        raise FormatError, "not a RIFF file" unless bytes.byteslice(0, 4) == "RIFF"
        raise FormatError, "not a WAVE file" unless bytes.byteslice(8, 4) == "WAVE"

        fmt = nil
        data = nil
        pos = 12
        total = bytes.bytesize
        while pos + 8 <= total
          chunk_id = bytes.byteslice(pos, 4)
          chunk_sz = u32le(bytes, pos + 4)
          body = bytes.byteslice(pos + 8, chunk_sz)
          case chunk_id
          when "fmt "
            fmt = Format.new(
              u16le(body, 0), u16le(body, 2), u32le(body, 4), u16le(body, 14)
            )
          when "data"
            data = body
          end
          pos += 8 + chunk_sz
          pos += 1 if chunk_sz.odd?
        end

        raise FormatError, "no fmt chunk" unless fmt
        raise FormatError, "no data chunk" unless data
        [fmt, data]
      end

      def self.expect_mono_s16!(fmt)
        unless fmt.audio_format == 1 && fmt.channels == 1 &&
               fmt.sample_rate == SAMPLE_RATE && fmt.bits_per_sample == 16
          raise FormatError,
                "expected 8kHz mono PCM16, got fmt=#{fmt.audio_format} " \
                "ch=#{fmt.channels} rate=#{fmt.sample_rate} bits=#{fmt.bits_per_sample}"
        end
        fmt
      end

      def self.u16le(s, off)
        s.getbyte(off) | (s.getbyte(off + 1) << 8)
      end

      def self.u32le(s, off)
        s.getbyte(off) | (s.getbyte(off + 1) << 8) |
          (s.getbyte(off + 2) << 16) | (s.getbyte(off + 3) << 24)
      end
    end
  end
end
