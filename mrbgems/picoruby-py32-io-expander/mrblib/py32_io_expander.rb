class PY32IOExpander
  I2C_ADDRESS       = 0x6F
  REG_LED_CFG       = 0x24
  REG_LED_COUNT     = 0x25
  REG_LED_RAM_START = 0x30

  def initialize(i2c)
    @i2c = i2c
  end

  private

  def write_reg(reg, *data)
    result = @i2c.write(I2C_ADDRESS, reg, *data, timeout: 1000)
    raise IOError, "PY32 write failed (reg: 0x#{reg.to_s(16)})" unless result > 0
    result
  end

  def read_reg(reg, length)
    data = @i2c.read(I2C_ADDRESS, length, reg, timeout: 1000)
    raise IOError, "PY32 read failed (reg: 0x#{reg.to_s(16)})" if data.nil? || data.empty?
    data.bytes
  end
end
