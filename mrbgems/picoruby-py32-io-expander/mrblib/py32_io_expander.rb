class PY32IOExpander
  I2C_ADDRESS = 0x6F

  REG_GPIO_M_L   = 0x03
  REG_GPIO_M_H   = 0x04
  REG_GPIO_PU_L  = 0x09
  REG_GPIO_PU_H  = 0x0A
  REG_GPIO_PD_L  = 0x0B
  REG_GPIO_PD_H  = 0x0C
  REG_GPIO_DRV_L = 0x13
  REG_GPIO_DRV_H = 0x14

  REG_LED_CFG       = 0x24
  REG_LED_RAM_START = 0x30

  LED_COUNT_MASK = 0x3F
  REFRESH_BIT    = 0x40

  def initialize(i2c)
    @i2c = i2c
  end

  def set_led_count(n)
    write_reg(REG_LED_CFG, n & LED_COUNT_MASK)
  end

  def write_led_ram(pixels)
    bytes = []
    pixels.each do |rgb|
      r, g, b = rgb[0], rgb[1], rgb[2]
      r5 = (r >> 3) & 0x1F
      g6 = (g >> 2) & 0x3F
      b5 = (b >> 3) & 0x1F
      packed = (r5 << 11) | (g6 << 5) | b5
      bytes << (packed & 0xFF)
      bytes << ((packed >> 8) & 0xFF)
    end
    write_reg(REG_LED_RAM_START, *bytes)
  end

  def refresh_leds
    write_reg(REG_LED_CFG, REFRESH_BIT)
  end

  def set_direction(pin, output)
    write_pin_bit(REG_GPIO_M_L, REG_GPIO_M_H, pin, output)
  end

  def set_pull_mode(pin, up)
    if up
      write_pin_bit(REG_GPIO_PD_L, REG_GPIO_PD_H, pin, false)
      write_pin_bit(REG_GPIO_PU_L, REG_GPIO_PU_H, pin, true)
    else
      write_pin_bit(REG_GPIO_PU_L, REG_GPIO_PU_H, pin, false)
      write_pin_bit(REG_GPIO_PD_L, REG_GPIO_PD_H, pin, true)
    end
  end

  def set_drive_mode(pin, open_drain)
    write_pin_bit(REG_GPIO_DRV_L, REG_GPIO_DRV_H, pin, open_drain)
  end

  private

  def write_pin_bit(reg_l, reg_h, pin, value)
    if pin < 8
      reg = reg_l
      bit = pin
    else
      reg = reg_h
      bit = pin - 8
    end
    current = read_reg(reg, 1)[0]
    new_val = value ? (current | (1 << bit)) : (current & ~(1 << bit) & 0xFF)
    write_reg(reg, new_val)
  end

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
