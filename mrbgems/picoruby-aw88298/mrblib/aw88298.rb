# Driver for the AW88298 speaker amplifier on I2C with an I2S PCM sink.
# Initializes the amp registers and plays mu-law audio through the sink.
class AW88298
  # @rbs!
  #   interface _Bus
  #     def write: (Integer i2c_adrs_7, *(Integer | String | Array[Integer]) outputs) -> Integer
  #   end
  #
  #   interface _Sink
  #     def write: (String pcm) -> Integer
  #   end
  # @rbs @i2c: _Bus
  # @rbs @i2s: _Sink

  AW88298_ADDR = 0x36
  AW_RATE_TBL  = [4, 5, 6, 8, 10, 11, 15, 20, 22, 44]
  CHUNK = 2046

  # Returns the value of register 0x06 for the given sample rate in Hz.
  #: (Integer sample_rate) -> Integer
  def self.aw88298_reg06(sample_rate)
    rate = (sample_rate + 1102) / 2205
    idx = 0
    last = AW_RATE_TBL.length - 1
    idx += 1 while idx < last && rate > AW_RATE_TBL[idx]
    idx | 0x14C0
  end

  # Returns the register writes for amp initialization as [register, high byte, low byte] triples.
  #: (Integer sample_rate) -> Array[Array[Integer]]
  def self.aw88298_init_writes(sample_rate)
    [[0x61, 0x0673], [0x04, 0x4040], [0x05, 0x0008],
     [0x06, aw88298_reg06(sample_rate)], [0x0C, 0x0064]].map do |reg, val|
      [reg, (val >> 8) & 0xFF, val & 0xFF]
    end
  end

  # Creates a driver over an I2C bus for the amp registers and an I2S sink for PCM.
  #: (i2c: _Bus, i2s: _Sink) -> void
  def initialize(i2c:, i2s:)
    @i2c = i2c
    @i2s = i2s
  end
  attr_reader :i2s #: _Sink

  # Writes the initialization registers for the given sample rate in Hz.
  #: (Integer sample_rate) -> void
  def init_amp(sample_rate)
    self.class.aw88298_init_writes(sample_rate).each do |reg, hi, lo|
      @i2c.write(AW88298_ADDR, reg, hi, lo)
    end
  end

  # Decodes mu-law bytes chunk by chunk on the second core and writes the PCM to the sink.
  # Returns once the last chunk is written.
  #: (String ulaw) -> void
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
