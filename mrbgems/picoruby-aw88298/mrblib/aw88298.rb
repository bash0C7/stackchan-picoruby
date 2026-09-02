# AW88298 class-D amp over I2C + I2S sample out (picoruby-i2s), with mu-law decode.
class AW88298
  ULAW_BIAS    = 0x84
  AW88298_ADDR = 0x36
  # M5Unified rate table for AW88298 reg 0x06 (M5Unified.cpp:_speaker_enabled_cb_cores3).
  AW_RATE_TBL  = [4, 5, 6, 8, 10, 11, 15, 20, 22, 44]

  # ITU G.711: one 8-bit mu-law code -> signed 16-bit linear sample.
  def self.ulaw_byte_to_linear(byte)
    u = (~byte) & 0xFF
    t = ((u & 0x0F) << 3) + ULAW_BIAS
    t = t << ((u & 0x70) >> 4)
    (u & 0x80) != 0 ? (ULAW_BIAS - t) : (t - ULAW_BIAS)
  end

  # Decode a mu-law byte string to a little-endian signed-16 PCM byte string.
  def self.ulaw_decode(ulaw)
    out = ""
    ulaw.each_byte do |b|
      v = ulaw_byte_to_linear(b) & 0xFFFF
      out << (v & 0xFF).chr
      out << ((v >> 8) & 0xFF).chr
    end
    out
  end

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
    @i2s.write(self.class.ulaw_decode(ulaw))
  end
end
