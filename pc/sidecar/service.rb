module StackchanSidecar
  PERSONA = "あなたは小さな卓上ロボットの『スタックチャン』です。" \
            "頭を撫でられたり、話しかけられたりしたら、その状況にあわせて" \
            "日本語で1〜2文の短い返事をしてください。19文字以内に収まる長さで。" \
            "ただの相槌や『はい』で済ませず、相手や場の状況に触れた具体的な返事をしてください。"

  TIMEOUT_MS   = 60_000
  DEFAULT_GAIN = 0.05

  class Service
    def initialize(session:, say:)
      @session = session
      @say     = say
    end

    def respond(prompt, ctx = {})
      situation = Service.situation(ctx)
      full = situation.empty? ? prompt : "#{situation}\n\n問いかけ: #{prompt}"
      @session.respond(full, timeout_ms: TIMEOUT_MS)
    rescue FoundationModel::GenerationError => e
      $stderr.write("[sidecar] respond error: #{e.class}: #{e.message}\n")
      nil
    end

    def synthesize(text, gain = nil, rate = nil)
      Ulaw.encode_pcm(@say.pcm(text, rate), gain || DEFAULT_GAIN)
    rescue Say::Error, Wav::FormatError => e
      $stderr.write("[sidecar] synthesize error: #{e.class}: #{e.message}\n")
      nil
    end

    def self.situation(ctx)
      return "" unless ctx.is_a?(Hash)
      parts = []
      parts << "今の表情: #{ctx[:last_face]}"               if ctx[:last_face]
      parts << "自分が直前に言ったこと: 「#{ctx[:last_say]}」"   if ctx[:last_say]
      parts << "直前に相手から聞いた話: 「#{ctx[:last_heard]}」" if ctx[:last_heard]
      parts.empty? ? "" : "今の状況:\n- " + parts.join("\n- ")
    end
  end

  class StubService
    def respond(prompt, ctx = {})
      "stub返答:#{prompt}"[0, 19]
    end

    def synthesize(text, gain = nil, rate = nil)
      "\xFF" * (text.length * 80)
    end
  end

  class Say
    class Error < StandardError; end

    def initialize(dir)
      @text_path = "#{dir}/sidecar-say.txt"
      @wav_path  = "#{dir}/sidecar-say.wav"
    end

    def pcm(text, rate)
      File.open(@text_path, "w") { |f| f.write(text) }
      cmd = "say -f '#{@text_path}' -o '#{@wav_path}' --file-format=WAVE --data-format=LEI16@#{Wav::SAMPLE_RATE}"
      cmd += " -r #{rate.to_i}" if rate
      io = IO.popen("#{cmd} 2>&1; echo exit:$?")
      out = io.read
      io.close
      File.delete(@text_path)
      raise Error, "say failed: #{out}" unless out.end_with?("exit:0\n")
      wav = File.open(@wav_path, "rb") { |f| f.read }
      File.delete(@wav_path)
      Wav.mono_s16(wav)
    end
  end

  module Wav
    SAMPLE_RATE = 8000

    class FormatError < StandardError; end

    def self.parse(bytes)
      raise FormatError, "not a RIFF file" unless bytes.byteslice(0, 4) == "RIFF"
      raise FormatError, "not a WAVE file" unless bytes.byteslice(8, 4) == "WAVE"
      fmt = nil
      data = nil
      pos = 12
      total = bytes.bytesize
      while pos + 8 <= total
        id = bytes.byteslice(pos, 4)
        size = u32le(bytes, pos + 4)
        body = bytes.byteslice(pos + 8, size)
        if id == "fmt "
          fmt = { audio_format: u16le(body, 0), channels: u16le(body, 2),
                  sample_rate: u32le(body, 4), bits: u16le(body, 14) }
        elsif id == "data"
          data = body
        end
        pos += 8 + size + (size % 2)
      end
      raise FormatError, "no fmt chunk" unless fmt
      raise FormatError, "no data chunk" unless data
      [fmt, data]
    end

    def self.mono_s16(bytes)
      fmt, data = parse(bytes)
      unless fmt[:audio_format] == 1 && fmt[:channels] == 1 &&
             fmt[:sample_rate] == SAMPLE_RATE && fmt[:bits] == 16
        raise FormatError, "expected 8kHz mono PCM16, got fmt=#{fmt[:audio_format]} " \
                           "ch=#{fmt[:channels]} rate=#{fmt[:sample_rate]} bits=#{fmt[:bits]}"
      end
      data
    end

    def self.u16le(s, off)
      s.getbyte(off) | (s.getbyte(off + 1) << 8)
    end

    def self.u32le(s, off)
      u16le(s, off) | (u16le(s, off + 2) << 16)
    end
  end

  module Ulaw
    BIAS = 0x84
    CLIP = 32635

    def self.exponent(v)
      e = 0
      while v > 1 && e < 7
        v >>= 1
        e += 1
      end
      e
    end

    def self.encode_sample(sample)
      sample = -32768 if sample < -32768
      sample = 32767 if sample > 32767
      sign = sample < 0 ? 0x80 : 0x00
      mag = sample < 0 ? -sample : sample
      mag = CLIP if mag > CLIP
      mag += BIAS
      exp = exponent((mag >> 7) & 0xFF)
      mantissa = (mag >> (exp + 3)) & 0x0F
      (~(sign | (exp << 4) | mantissa)) & 0xFF
    end

    def self.encode_pcm(pcm_le16, gain = 1.0)
      n = pcm_le16.bytesize / 2
      out = "\0" * n
      i = 0
      while i < n
        s = pcm_le16.getbyte(2 * i) | (pcm_le16.getbyte(2 * i + 1) << 8)
        s -= 0x10000 if s >= 0x8000
        s = (s * gain).to_i unless gain == 1.0
        out.setbyte(i, encode_sample(s))
        i += 1
      end
      out
    end
  end
end
