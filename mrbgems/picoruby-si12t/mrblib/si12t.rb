# Driver for the Si12T capacitive touch sensor with three head zones on I2C.
# Reports a touch once per press as the strongest zone index.
class Si12T
  # @rbs!
  #   interface _Bus
  #     def write: (Integer i2c_adrs_7, *(Integer | String | Array[Integer]) outputs) -> Integer
  #     def read: (Integer i2c_adrs_7, Integer len, *(Integer | String | Array[Integer]) outputs) -> String
  #   end
  # @rbs @i2c: _Bus
  # @rbs @prev_touched: bool

  ADDR        = 0x68
  REG_CTRL1   = 0x08
  REG_CTRL2   = 0x09
  REG_OUTPUT1 = 0x10
  ENABLE_REGS = (0x0A..0x0F)
  SENS_REGS   = (0x02..0x06)
  ZONE_COUNT  = 3

  # Creates a driver over the I2C bus and initializes the sensor.
  #: (_Bus i2c) -> void
  def initialize(i2c)
    @i2c          = i2c
    @prev_touched = false
    init_sensor
  end

  # Writes the enable, control and sensitivity registers.
  #: () -> void
  def init_sensor
    ENABLE_REGS.each { |r| @i2c.write(ADDR, r, 0x00) }
    @i2c.write(ADDR, REG_CTRL2, 0x0F)
    @i2c.write(ADDR, REG_CTRL2, 0x07)
    @i2c.write(ADDR, REG_CTRL1, 0x22)
    SENS_REGS.each { |r| @i2c.write(ADDR, r, 0x33) }
  end

  # Reads the output register and returns the 2-bit strength of each of the three zones.
  #: () -> Array[Integer]
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

  # Returns the index of the strongest zone when a touch starts, otherwise nil.
  # A held touch does not report again until it is released.
  #: () -> Integer?
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
