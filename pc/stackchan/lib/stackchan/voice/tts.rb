# frozen_string_literal: true

require "open3"
require "tempfile"
require_relative "wav"
require_relative "ulaw"

# Namespace of the Mac-side StackChan host library.
module Stackchan
  # Speech synthesis and audio encoding for the robot speaker.
  module Voice
    # Synthesizes speech with the macOS say command and encodes it to mu-law 8 kHz.
    class Tts
      # @rbs @gain: Float
      # @rbs @rate: Integer?

      # Raised when say or afconvert fails.
      class SynthError < StandardError; end

      DEFAULT_GAIN = 0.05

      # Builds a synthesizer with a PCM gain factor and an optional say rate in words per minute.
      #: (?gain: Float, ?rate: Integer?) -> void
      def initialize(gain: DEFAULT_GAIN, rate: nil)
        @gain = gain
        @rate = rate
      end

      # Returns mu-law bytes of text spoken at 8 kHz. Raises SynthError when say or afconvert fails.
      #: (String text) -> String
      def synthesize(text)
        pcm = synthesize_pcm(text)
        Ulaw.encode_pcm(pcm, gain: @gain)
      end

      private

      # Returns 8 kHz mono PCM16 bytes of text via say and afconvert.
      #: (String text) -> String
      def synthesize_pcm(text)
        aiff = Tempfile.new(["stackchan-voice", ".aiff"])
        wav  = Tempfile.new(["stackchan-voice", ".wav"])
        begin
          run_say(text, aiff.path)
          run_afconvert(aiff.path, wav.path)
          fmt, data = Wav.parse(File.binread(wav.path))
          Wav.expect_mono_s16!(fmt)
          data
        ensure
          aiff.close!
          wav.close!
        end
      end

      # Writes the spoken text to an AIFF file. Raises SynthError when say fails.
      #: (String text, String out_path) -> void
      def run_say(text, out_path)
        cmd = ["say", "-o", out_path]
        cmd += ["-r", @rate.to_s] if @rate
        cmd << text
        _out, err, st = Open3.capture3(*cmd)
        raise SynthError, "say failed: #{err.strip}" unless st.success?
      end

      # Converts an AIFF file to 8 kHz mono PCM16 WAVE. Raises SynthError when afconvert fails.
      #: (String in_path, String out_path) -> void
      def run_afconvert(in_path, out_path)
        cmd = ["afconvert", "-f", "WAVE", "-d", "LEI16@#{Wav::SAMPLE_RATE}", "-c", "1", in_path, out_path]
        _out, err, st = Open3.capture3(*cmd)
        raise SynthError, "afconvert failed: #{err.strip}" unless st.success?
      end
    end
  end
end
