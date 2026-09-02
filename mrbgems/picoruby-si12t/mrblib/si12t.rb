# Si12T 3-zone head touch, I2C 0x68 on the system bus.
# OUTPUT1 (0x10): 2 bits per zone, 0..3 (NONE/LOW/MID/HIGH).
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
    @i2c.write(ADDR, REG_CTRL2, 0x0F)   # S/W reset + sleep enable
    @i2c.write(ADDR, REG_CTRL2, 0x07)
    @i2c.write(ADDR, REG_CTRL1, 0x22)   # auto mode, FTC, response 4(2+2)
    SENS_REGS.each { |r| @i2c.write(ADDR, r, 0x33) }  # TYPE_LOW / LEVEL_3
  end

  # [z0, z1, z2] intensities 0..3; [0,0,0] on a failed/empty read.
  def read_zones
    raw  = @i2c.read(ADDR, 1, REG_OUTPUT1)
    byte = raw && raw.bytes[0]
    return [0, 0, 0] unless byte
    z = []
    i = 0
    while i < ZONE_COUNT
      z << ((byte >> (2 * i)) & 0x03)
      i += 1
    end
    z
  end

  # Rising-edge: returns the active zone index ONCE on touch onset (highest
  # intensity; lowest index on a tie), nil while held and until release.
  def poll
    zones   = read_zones
    touched = zones.any? { |v| v > 0 }
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
