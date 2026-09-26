# AW88298 class-D amp over I2C + I2S sample out (picoruby-i2s).
# mu-law is decoded on core 1 by the ulaw_decode AOT kernel (aot/kernels),
# one chunk ahead of the I2S write.
class AW88298
  AW88298_ADDR = 0x36
  # M5Unified rate table for AW88298 reg 0x06 (M5Unified.cpp:_speaker_enabled_cb_cores3).
  AW_RATE_TBL  = [4, 5, 6, 8, 10, 11, 15, 20, 22, 44]
  # The 2n + 3 byte reply has to fit picoruby-multicore's 4096-byte buffer.
  CHUNK = 2046

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
    pos = 0
    job = Multicore.spawn(:ulaw_decode, ulaw.byteslice(0, CHUNK))
    while job
      until job.done?
      end
      pcm = job.value
      pos += CHUNK
      job = pos < ulaw.bytesize ? Multicore.spawn(:ulaw_decode, ulaw.byteslice(pos, CHUNK)) : nil
      @i2s.write(pcm)
    end
  end
end
