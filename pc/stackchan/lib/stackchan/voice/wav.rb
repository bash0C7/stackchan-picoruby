# frozen_string_literal: true

# Namespace of the Mac-side StackChan host library.
module Stackchan
  # Speech synthesis and audio encoding for the robot speaker.
  module Voice
    # Minimal RIFF WAVE reader for the PCM that afconvert writes.
    module Wav
      SAMPLE_RATE = 8000

      # The fmt chunk fields of a WAVE file.
      Format = Struct.new(
        :audio_format, #: Integer
        :channels, #: Integer
        :sample_rate, #: Integer
        :bits_per_sample #: Integer
      )

      # Raised when WAVE bytes are malformed or not 8 kHz mono PCM16.
      class FormatError < StandardError; end

      # Returns the fmt chunk and the data chunk bytes of a WAVE file. Raises FormatError on a malformed file.
      #: (String bytes) -> [Format, String]
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

      # Returns fmt when it is 8 kHz mono PCM16. Raises FormatError otherwise.
      #: (Format fmt) -> Format
      def self.expect_mono_s16!(fmt)
        unless fmt.audio_format == 1 && fmt.channels == 1 &&
               fmt.sample_rate == SAMPLE_RATE && fmt.bits_per_sample == 16
          raise FormatError,
                "expected 8kHz mono PCM16, got fmt=#{fmt.audio_format} " \
                "ch=#{fmt.channels} rate=#{fmt.sample_rate} bits=#{fmt.bits_per_sample}"
        end
        fmt
      end

      # Returns the little-endian unsigned 16-bit value at byte offset off.
      #: (String s, Integer off) -> Integer
      def self.u16le(s, off)
        s.getbyte(off) | (s.getbyte(off + 1) << 8)
      end

      # Returns the little-endian unsigned 32-bit value at byte offset off.
      #: (String s, Integer off) -> Integer
      def self.u32le(s, off)
        s.getbyte(off) | (s.getbyte(off + 1) << 8) |
          (s.getbyte(off + 2) << 16) | (s.getbyte(off + 3) << 24)
      end
    end
  end
end
