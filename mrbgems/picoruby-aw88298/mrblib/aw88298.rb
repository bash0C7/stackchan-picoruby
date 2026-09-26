# AW88298 class-D amp over I2C + I2S sample out (picoruby-i2s).
# play_ulaw decodes on the other core when the firmware carries picoruby-multicore
# and the ulaw_decode kernel (aot/kernels/stackchan_aot.rb), overlapping each
# chunk's decode with the previous chunk's blocking I2S write. Without them it
# decodes here with AW88298.ulaw_decode, the same bytes.
class AW88298
  AW88298_ADDR = 0x36
  # M5Unified rate table for AW88298 reg 0x06 (M5Unified.cpp:_speaker_enabled_cb_cores3).
  AW_RATE_TBL  = [4, 5, 6, 8, 10, 11, 15, 20, 22, 44]
  # mu-law bytes per kernel call: the 2*n + 3 byte reply must fit picoruby-multicore's
  # 4096-byte output buffer.
  MULTICORE_CHUNK = 2046

  # AW88298 reg 0x06 value for a sample rate (M5Unified formula).
  def self.aw88298_reg06(sample_rate)
    rate = (sample_rate + 1102) / 2205
    idx = 0
    while rate > AW_RATE_TBL[idx]
      idx += 1
      break if idx >= AW_RATE_TBL.length
    end
    idx = AW_RATE_TBL.length - 1 if idx >= AW_RATE_TBL.length
    idx | 0x14C0
  end

  # Ordered AW88298 init writes as [reg, hi, lo] (16-bit big-endian) triples.
  def self.aw88298_init_writes(sample_rate)
    [[0x61, 0x0673], [0x04, 0x4040], [0x05, 0x0008],
     [0x06, aw88298_reg06(sample_rate)], [0x0C, 0x0064]].map do |reg, val|
      [reg, (val >> 8) & 0xFF, val & 0xFF]
    end
  end

  # ITU-T G.711 mu-law -> little-endian signed 16-bit PCM, two bytes per code.
  def self.ulaw_decode(ulaw)
    n = ulaw.bytesize
    out = "\0" * (n * 2)
    i = 0
    while i < n
      u = (~ulaw.getbyte(i)) & 0xFF
      t = (((u & 0x0F) << 3) + 0x84) << ((u & 0x70) >> 4)
      v = ((u & 0x80) != 0 ? (0x84 - t) : (t - 0x84)) & 0xFFFF
      out.setbyte(i * 2, v & 0xFF)
      out.setbyte(i * 2 + 1, v >> 8)
      i += 1
    end
    out
  end

  def initialize(i2c:, i2s:)
    @i2c = i2c
    @i2s = i2s
  end
  attr_reader :i2c, :i2s

  # Power the amp over I2C.
  def init_amp(sample_rate)
    self.class.aw88298_init_writes(sample_rate).each do |reg, hi, lo|
      @i2c.write(AW88298_ADDR, reg, hi, lo)
    end
  end

  def play_ulaw(ulaw)
    if Object.const_defined?(:Multicore)
      play_ulaw_multicore(ulaw)
    else
      @i2s.write(self.class.ulaw_decode(ulaw))
    end
  end

  private

  # Chunk k+1 decodes on the other core while chunk k is written to I2S. Only
  # I2S runs here meanwhile, so the AOT runtime is never used from both cores
  # at once. A multicore failure plays the rest decoded here.
  def play_ulaw_multicore(ulaw)
    n = ulaw.bytesize
    pos = 0      # first byte not yet decoded
    job = nil
    pcm = nil    # decoded, not yet written
    begin
      job = Multicore.spawn(:ulaw_decode, ulaw.byteslice(0, MULTICORE_CHUNK))
      while job
        until job.done?
        end
        pcm = job.value
        job = nil
        pos += MULTICORE_CHUNK
        job = Multicore.spawn(:ulaw_decode, ulaw.byteslice(pos, MULTICORE_CHUNK)) if pos < n
        @i2s.write(pcm)
        pcm = nil
      end
    rescue Multicore::Error
      job.discard if job
      @i2s.write(pcm) if pcm
      @i2s.write(self.class.ulaw_decode(ulaw.byteslice(pos, n - pos))) if pos < n
    end
  end
end
