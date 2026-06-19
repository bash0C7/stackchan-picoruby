# frozen_string_literal: true

require "open3"
require "tempfile"
require_relative "wav"
require_relative "ulaw"

module StackchanVoice
  # macOS text-to-speech -> 8 kHz mono mu-law bytes for the device.
  #
  # Pipeline: `say -o aiff` (natural rate) -> `afconvert` resample to 8 kHz mono
  # 16-bit PCM WAV -> pure-Ruby G.711 mu-law encode (with gain). afconvert does
  # only the resample; the mu-law encoding stays in Ruby so it round-trips
  # exactly against the device decoder and is host-tested without afconvert.
  class Tts
    class SynthError < StandardError; end

    DEFAULT_GAIN = 0.1   # HITL 2026-06-19: 0.3 was far too loud on the 1W speaker (the bring-up tone was ~0.37 full-scale and painful); tune up per-run with --gain.

    def initialize(voice: nil, gain: DEFAULT_GAIN)
      @voice = voice
      @gain  = gain
    end

    # text (String) -> mu-law byte string (8 kHz mono).
    def synthesize(text)
      pcm = synthesize_pcm(text)
      Ulaw.encode_pcm(pcm, gain: @gain)
    end

    # text -> 8 kHz mono 16-bit LE PCM byte string (via say + afconvert).
    def synthesize_pcm(text)
      aiff = Tempfile.new(["stackchan-voice", ".aiff"])
      wav  = Tempfile.new(["stackchan-voice", ".wav"])
      begin
        run_say(text, aiff.path)
        run_afconvert(aiff.path, wav.path)
        fmt, data = Wav.parse(File.binread(wav.path))
        Wav.expect_8k_mono_s16!(fmt)
        data
      ensure
        aiff.close!
        wav.close!
      end
    end

    private

    def run_say(text, out_path)
      cmd = ["say", "-o", out_path]
      cmd += ["-v", @voice] if @voice
      cmd << text
      _out, err, st = Open3.capture3(*cmd)
      raise SynthError, "say failed: #{err.strip}" unless st.success?
    end

    def run_afconvert(in_path, out_path)
      # -f WAVE -d LEI16@8000 -c 1 : WAV container, 8 kHz mono signed-16 LE PCM.
      cmd = ["afconvert", "-f", "WAVE", "-d", "LEI16@8000", "-c", "1", in_path, out_path]
      _out, err, st = Open3.capture3(*cmd)
      raise SynthError, "afconvert failed: #{err.strip}" unless st.success?
    end
  end
end
