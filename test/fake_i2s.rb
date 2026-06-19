# Host fake for the standalone picoruby-i2s gem's `I2S` class (device-only C).
# Records init args and accumulates written PCM so app `Speaker` code is host-testable.
class I2S
  attr_reader :inited_with, :written

  def initialize(sample_rate:, bits: 16, mono: true)
    @inited_with = { sample_rate: sample_rate, bits: bits, mono: mono }
    @written = ""
  end

  def write(pcm)
    @written << pcm
    pcm.bytesize
  end

  def close
    0
  end
end
