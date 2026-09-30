# frozen_string_literal: true

require "open3"
require "tempfile"
require_relative "wav"
require_relative "ulaw"

module Stackchan
  module Voice
    class Tts
      class SynthError < StandardError; end

      DEFAULT_GAIN = 0.05

      def initialize(gain: DEFAULT_GAIN, rate: nil)
        @gain = gain
        @rate = rate
      end

      def synthesize(text)
        pcm = synthesize_pcm(text)
        Ulaw.encode_pcm(pcm, gain: @gain)
      end

      private

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

      def run_say(text, out_path)
        cmd = ["say", "-o", out_path]
        cmd += ["-r", @rate.to_s] if @rate
        cmd << text
        _out, err, st = Open3.capture3(*cmd)
        raise SynthError, "say failed: #{err.strip}" unless st.success?
      end

      def run_afconvert(in_path, out_path)
        cmd = ["afconvert", "-f", "WAVE", "-d", "LEI16@#{Wav::SAMPLE_RATE}", "-c", "1", in_path, out_path]
        _out, err, st = Open3.capture3(*cmd)
        raise SynthError, "afconvert failed: #{err.strip}" unless st.success?
      end
    end
  end
end
