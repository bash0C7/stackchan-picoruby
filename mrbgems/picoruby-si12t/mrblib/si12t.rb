class Si12T
  ADDR        = 0x68
  REG_CTRL1   = 0x08
  REG_CTRL2   = 0x09
  REG_OUTPUT1 = 0x10
  ENABLE_REGS = (0x0A..0x0F)
  SENS_REGS   = (0x02..0x06)
  ZONE_COUNT  = 3

  def initialize(i2c)
    @i2c          = i2c
    @prev_touched = false
    init_sensor
  end

  def init_sensor
    ENABLE_REGS.each { |r| @i2c.write(ADDR, r, 0x00) }
    @i2c.write(ADDR, REG_CTRL2, 0x0F)
    @i2c.write(ADDR, REG_CTRL2, 0x07)
    @i2c.write(ADDR, REG_CTRL1, 0x22)
    SENS_REGS.each { |r| @i2c.write(ADDR, r, 0x33) }
  end

  def read_zones
    byte = @i2c.read(ADDR, 1, REG_OUTPUT1).getbyte(0)
    z = []
    i = 0
    while i < ZONE_COUNT
      z << ((byte >> (2 * i)) & 0x03)
      i += 1
    end
    z
  end

  def poll
    zones   = read_zones
    touched = zones[0] > 0 || zones[1] > 0 || zones[2] > 0
    if touched && !@prev_touched
      @prev_touched = true
      best_i = 0
      best_v = -1
      i = 0
      while i < zones.size
        if zones[i] > best_v
          best_v = zones[i]
          best_i = i
        end
        i += 1
      end
      return best_i
    end
    @prev_touched = touched
    nil
  end
end
