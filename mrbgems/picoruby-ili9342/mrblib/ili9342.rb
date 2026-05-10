require 'spi'
require 'gpio'

class ILI9342
  # MADCTL bits: MY|MX|MV|ML|BGR|MH|0|0
  # Values per docs/cores3-pinout-and-init.md (CoreS3 native landscape, BGR).
  MADCTL_LANDSCAPE      = 0x08  # default: swap_xy=false, mirror_*=false, BGR=1
  MADCTL_PORTRAIT       = 0x68  # MV+MX+BGR (rotate 90° CW)
  MADCTL_LANDSCAPE_FLIP = 0xC8  # MY+MX+BGR (180° rotation)
  MADCTL_PORTRAIT_FLIP  = 0xA8  # MV+MY+BGR (rotate 90° CCW)

  # Commands
  CMD_SWRESET = 0x01
  CMD_SLPOUT  = 0x11
  CMD_DISPON  = 0x29
  CMD_CASET   = 0x2A
  CMD_RASET   = 0x2B
  CMD_RAMWR   = 0x2C
  CMD_MADCTL  = 0x36
  CMD_COLMOD  = 0x3A

  # Verified CoreS3 init sequence — see docs/cores3-pinout-and-init.md.
  # Mirrors ESP-IDF esp_lcd_new_panel_ili9341 / LovyanGFX Panel_ILI9341::init().
  # Each entry: [cmd_byte, [payload_bytes...], delay_ms]
  INIT_COMMANDS = [
    [CMD_SWRESET, [],                                                  120],
    [CMD_SLPOUT,  [],                                                  120],

    # Power Control B
    [0xCF, [0x00, 0xC1, 0x30],                                           0],
    # Power on sequence control
    [0xED, [0x64, 0x03, 0x12, 0x81],                                     0],
    # Driver timing control A
    [0xE8, [0x85, 0x00, 0x78],                                           0],
    # Power Control A
    [0xCB, [0x39, 0x2C, 0x00, 0x34, 0x02],                               0],
    # Pump ratio control
    [0xF7, [0x20],                                                       0],
    # Driver timing control B
    [0xEA, [0x00, 0x00],                                                 0],

    # Power Control 1
    [0xC0, [0x23],                                                       0],  # VRH = 4.60V
    # Power Control 2
    [0xC1, [0x10],                                                       0],
    # VCOM Control 1
    [0xC5, [0x3E, 0x28],                                                 0],
    # VCOM Control 2
    [0xC7, [0x86],                                                       0],

    # Memory Access Control (MADCTL) — landscape default, BGR
    # 0x08 = MX=0 MY=0 MV=0 ML=0 BGR=1 MH=0
    # CoreS3 native is landscape 320x240 with swap_xy=false, so MADCTL=0x08
    [CMD_MADCTL, [0x08],                                                 0],

    # Pixel Format Set: 16-bit RGB565 (DPI/DBI = 0x55)
    [CMD_COLMOD, [0x55],                                                 0],

    # Frame Rate Control: 70 Hz default
    [0xB1, [0x00, 0x18],                                                 0],
    # Display Function Control
    [0xB6, [0x08, 0x82, 0x27],                                           0],

    # Enable 3G (gamma correction disabled)
    [0xF2, [0x00],                                                       0],
    # Gamma curve selected (Gamma 2.2)
    [0x26, [0x01],                                                       0],

    # Positive Gamma Correction
    [0xE0, [0x0F, 0x31, 0x2B, 0x0C, 0x0E, 0x08, 0x4E,
            0xF1, 0x37, 0x07, 0x10, 0x03, 0x0E, 0x09, 0x00],             0],
    # Negative Gamma Correction
    [0xE1, [0x00, 0x0E, 0x14, 0x03, 0x11, 0x07, 0x31,
            0xC1, 0x48, 0x08, 0x0F, 0x0C, 0x31, 0x36, 0x0F],             0],

    # Display inversion ON (upstream calls esp_lcd_panel_invert_color(panel, true))
    [0x21, [],                                                           0],

    [CMD_DISPON, [],                                                   100],
  ].freeze

  module Color
    BLACK = 0x0000
    WHITE = 0xFFFF
    RED   = 0xF800
    GREEN = 0x07E0
    BLUE  = 0x001F
  end

  def self.rgb(r, g, b)
    ((r & 0xF8) << 8) | ((g & 0xFC) << 3) | ((b & 0xF8) >> 3)
  end

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

  def fill(rgb565)
    set_window(0, 0, @width - 1, @height - 1)
    hi = (rgb565 >> 8) & 0xFF
    lo = rgb565 & 0xFF
    chunk = [hi, lo] * 256
    @cs.write(0)
    @dc.write(0)
    @spi.write(CMD_RAMWR)
    @dc.write(1)
    full_chunks, leftover_pairs = (@width * @height).divmod(256)
    full_chunks.times { @spi.write(*chunk) }
    @spi.write(*([hi, lo] * leftover_pairs)) if leftover_pairs > 0
    @cs.write(1)
  end

  def draw_pixel(x, y, rgb565)
    return if x < 0 || x >= @width || y < 0 || y >= @height
    set_window(x, y, x, y)
    @cs.write(0)
    @dc.write(0)
    @spi.write(CMD_RAMWR)
    @dc.write(1)
    @spi.write((rgb565 >> 8) & 0xFF, rgb565 & 0xFF)
    @cs.write(1)
  end

  def draw_rect(x, y, w, h, rgb565, fill: false)
    return if w <= 0 || h <= 0
    x0 = [x, 0].max
    y0 = [y, 0].max
    x1 = [x + w - 1, @width - 1].min
    y1 = [y + h - 1, @height - 1].min
    return if x0 > x1 || y0 > y1

    if fill
      set_window(x0, y0, x1, y1)
      hi = (rgb565 >> 8) & 0xFF
      lo = rgb565 & 0xFF
      count = (x1 - x0 + 1) * (y1 - y0 + 1)
      @cs.write(0)
      @dc.write(0)
      @spi.write(CMD_RAMWR)
      @dc.write(1)
      count.times { @spi.write(hi, lo) }
      @cs.write(1)
    else
      draw_line(x0, y0, x1, y0, rgb565)
      draw_line(x0, y1, x1, y1, rgb565)
      draw_line(x0, y0, x0, y1, rgb565)
      draw_line(x1, y0, x1, y1, rgb565)
    end
  end

  # Temporary stub — replaced with Bresenham in Task 12.
  def draw_line(x0, y0, x1, y1, rgb565)
    draw_pixel(x0, y0, rgb565)
    draw_pixel(x1, y1, rgb565)
  end

  private

  def set_window(x0, y0, x1, y1)
    write_command(CMD_CASET, [(x0 >> 8) & 0xFF, x0 & 0xFF, (x1 >> 8) & 0xFF, x1 & 0xFF])
    write_command(CMD_RASET, [(y0 >> 8) & 0xFF, y0 & 0xFF, (y1 >> 8) & 0xFF, y1 & 0xFF])
  end

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
