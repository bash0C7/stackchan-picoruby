class PY32IOExpander
  I2C_ADDRESS       = 0x6F
  REG_LED_CFG       = 0x24
  REG_LED_COUNT     = 0x25
  REG_LED_RAM_START = 0x30

  def initialize(i2c)
    @i2c = i2c
  end
end
