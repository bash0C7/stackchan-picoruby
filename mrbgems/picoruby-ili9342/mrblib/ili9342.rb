require 'spi'
require 'gpio'

class ILI9342
  # MADCTL bits: MY|MX|MV|ML|RGB|MH|0|0
  MADCTL_PORTRAIT       = 0x08  # row=0, col=0, BGR
  MADCTL_LANDSCAPE      = 0x68  # row=1, col=1, swap, BGR
  MADCTL_PORTRAIT_FLIP  = 0xC8
  MADCTL_LANDSCAPE_FLIP = 0xA8

  # Commands
  CMD_SWRESET = 0x01
  CMD_SLPOUT  = 0x11
  CMD_DISPON  = 0x29
  CMD_CASET   = 0x2A
  CMD_RASET   = 0x2B
  CMD_RAMWR   = 0x2C
  CMD_MADCTL  = 0x36
  CMD_COLMOD  = 0x3A

  # Placeholder init — replaced in REFACTOR step with verified CoreS3 sequence
  # from docs/cores3-pinout-and-init.md.
  INIT_COMMANDS = [
    [CMD_SWRESET, [],     120],
    [CMD_SLPOUT,  [],     120],
    [CMD_COLMOD,  [0x55],   0],   # 16-bit/pixel
    [CMD_DISPON,  [],     100],
  ].freeze

  def initialize(spi:, dc_pin:, cs_pin:, rst_pin:, bl_pin:, width:, height:, rotation: :landscape)
    @spi    = spi
    @dc     = dc_pin
    @cs     = cs_pin
    @rst    = rst_pin
    @bl     = bl_pin
    @width  = width
    @height = height
    @rotation = rotation

    hardware_reset
    send_init_sequence
    set_rotation(rotation)
    set_backlight(true)
  end

  attr_reader :width, :height, :rotation

  def set_backlight(on)
    @bl.write(on ? 1 : 0)
  end

  def set_rotation(sym)
    val = case sym
          when :portrait        then MADCTL_PORTRAIT
          when :landscape       then MADCTL_LANDSCAPE
          when :portrait_flip   then MADCTL_PORTRAIT_FLIP
          when :landscape_flip  then MADCTL_LANDSCAPE_FLIP
          else raise ArgumentError, "rotation must be one of :portrait, :landscape, :portrait_flip, :landscape_flip"
          end
    write_command(CMD_MADCTL, [val])
    @rotation = sym
  end

  private

  def hardware_reset
    @rst.write(1)
    Machine.delay_ms(5)
    @rst.write(0)
    Machine.delay_ms(20)
    @rst.write(1)
    Machine.delay_ms(120)
  end

  def send_init_sequence
    INIT_COMMANDS.each do |cmd, payload, delay_ms|
      write_command(cmd, payload)
      Machine.delay_ms(delay_ms) if delay_ms > 0
    end
  end

  def write_command(cmd, payload = [])
    @cs.write(0)
    @dc.write(0)
    @spi.write(cmd & 0xFF)
    if payload && !payload.empty?
      @dc.write(1)
      @spi.write(*payload)
    end
    @cs.write(1)
  end
end
