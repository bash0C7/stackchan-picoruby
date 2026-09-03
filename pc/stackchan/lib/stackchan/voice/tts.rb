# frozen_string_literal: true

require "open3"
require "tempfile"
require_relative "wav"
require_relative "ulaw"

module Stackchan::Voice
  # macOS text-to-speech -> 8 kHz mono mu-law bytes for the device.
  #
  # Pipeline: `say -o aiff` (natural rate) -> `afconvert` resample to mono
  # 16-bit PCM WAV -> pure-Ruby G.711 mu-law encode (with gain). afconvert does
  # only the resample; the mu-law encoding stays in Ruby so it round-trips
  # exactly against the device decoder and is host-tested without afconvert.
  class Tts
    class SynthError < StandardError; end

    # The 1W speaker breaks up on peaks well before the digital path does:
    # `say` output reaches only about 19900 of full scale and nothing clips
    # through afconvert or the mu-law encode, so audible distortion is the
    # speaker being overdriven, not the codec. Tune per run with --gain.
    DEFAULT_GAIN = 0.05

    def initialize(voice: nil, gain: DEFAULT_GAIN, rate: nil)
      @voice = voice
      @gain  = gain
      @rate  = rate
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
        Wav.expect_mono_s16!(fmt)
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
      cmd += ["-r", @rate.to_s] if @rate
      cmd << text
      _out, err, st = Open3.capture3(*cmd)
      raise SynthError, "say failed: #{err.strip}" unless st.success?
    end

    def run_afconvert(in_path, out_path)
      # WAV container, mono signed-16 LE PCM at the device's rate.
      cmd = ["afconvert", "-f", "WAVE", "-d", "LEI16@#{Wav::SAMPLE_RATE}", "-c", "1", in_path, out_path]
      _out, err, st = Open3.capture3(*cmd)
      raise SynthError, "afconvert failed: #{err.strip}" unless st.success?
    end
  end
end
