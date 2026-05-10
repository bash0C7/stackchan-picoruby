require 'spi'
require 'gpio'

class ILI9342
  # MADCTL bits: MY|MX|MV|ML|BGR|MH|0|0
  # Values per docs/cores3-pinout-and-init.md (CoreS3 native landscape, BGR).
  MADCTL_LANDSCAPE      = 0x08  # default: swap_xy=false, mirror_*=false, BGR=1
  MADCTL_PORTRAIT       = 0x68  # MV+MX+BGR (rotate 90° CW)
  MADCTL_LANDSCAPE_FLIP = 0xC8  # MY+MX+BGR (180° rotation)
  MADCTL_PORTRAIT_FLIP  = 0xA8  # MV+MY+BGR (rotate 90° CCW)

  # Commands — only those actually emitted by the driver. References point
  # to the Ilitek ILI9342C datasheet V100 sections.
  CMD_SWRESET = 0x01  # §8.2.2  Software Reset
  CMD_SLPOUT  = 0x11  # §8.2.12 Sleep OUT
  CMD_INVON   = 0x21  # §8.2.16 Display Inversion ON (CoreS3 panel needs invert)
  CMD_DISPON  = 0x29  # §8.2.19 Display ON
  CMD_CASET   = 0x2A  # §8.2.20 Column Address Set
  CMD_RASET   = 0x2B  # §8.2.21 Page Address Set
  CMD_RAMWR   = 0x2C  # §8.2.22 Memory Write
  CMD_MADCTL  = 0x36  # §8.2.29 Memory Access Control
  CMD_COLMOD  = 0x3A  # §8.2.33 COLMOD: Pixel Format Set
  CMD_SETEXTC = 0xC8  # §8.3.24 Set EXTC — unlocks Level-2 commands

  # SETEXTC payload that unlocks Level-2 commands. Until this is sent, every
  # command in the 0xB0..0xFF range is treated as NOP. See §8.3.x where each
  # Level-2 command is annotated "Set EXTC(C8h)=FF,93,42 to enable this command".
  SETEXTC_UNLOCK_PAYLOAD = [0xFF, 0x93, 0x42].freeze

  # Minimal ILI9342C-compliant init. Only datasheet-verified Level-1 bytes
  # plus the Level-2 unlock prologue. Power / VCOM / frame-rate / gamma are
  # NOT customised here — those fall back to the chip's hardware-reset
  # defaults (sane per datasheet, see audit doc).
  #
  # MADCTL (0x36) is intentionally absent: set_rotation() is the sole owner
  # so the user's `rotation:` kwarg is respected.
  #
  # Each entry: [cmd_byte, [payload_bytes...], delay_ms]
  INIT_COMMANDS = [
    [CMD_SETEXTC, SETEXTC_UNLOCK_PAYLOAD,                                0],
    [CMD_SWRESET, [],                                                  120],
    [CMD_SLPOUT,  [],                                                  120],
    [CMD_COLMOD,  [0x55],                                                0],  # 16-bit RGB565
    [CMD_INVON,   [],                                                    0],  # CoreS3 panel inverts
    [CMD_DISPON,  [],                                                  100],
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
    fill_window(0, 0, @width - 1, @height - 1, rgb565)
  end

  def draw_pixel(x, y, rgb565)
    return if x < 0 || x >= @width || y < 0 || y >= @height
    set_window(x, y, x, y)
    write_pixels do
      @spi.write((rgb565 >> 8) & 0xFF, rgb565 & 0xFF)
    end
  end

  def draw_rect(x, y, w, h, rgb565, fill: false)
    return if w <= 0 || h <= 0
    x0 = [x, 0].max
    y0 = [y, 0].max
    x1 = [x + w - 1, @width - 1].min
    y1 = [y + h - 1, @height - 1].min
    return if x0 > x1 || y0 > y1

    if fill
      fill_window(x0, y0, x1, y1, rgb565)
    else
      draw_line(x0, y0, x1, y0, rgb565)
      draw_line(x0, y1, x1, y1, rgb565)
      draw_line(x0, y0, x0, y1, rgb565)
      draw_line(x1, y0, x1, y1, rgb565)
    end
  end

  def draw_line(x0, y0, x1, y1, rgb565)
    dx = (x1 - x0).abs
    dy = -(y1 - y0).abs
    sx = x0 < x1 ? 1 : -1
    sy = y0 < y1 ? 1 : -1
    err = dx + dy
    x = x0
    y = y0
    loop do
      draw_pixel(x, y, rgb565)
      break if x == x1 && y == y1
      e2 = err * 2
      if e2 >= dy
        err += dy
        x += sx
      end
      if e2 <= dx
        err += dx
        y += sy
      end
    end
  end

  def draw_ellipse(cx, cy, rx, ry, rgb565, fill: false)
    return if rx <= 0 || ry <= 0

    rx2 = rx * rx
    ry2 = ry * ry
    two_rx2 = 2 * rx2
    two_ry2 = 2 * ry2

    # Region 1
    x = 0
    y = ry
    px = 0
    py = two_rx2 * y
    p = (ry2 - rx2 * ry + rx2 / 4.0).round
    plot_ellipse_points(cx, cy, x, y, rgb565, fill)
    while px < py
      x += 1
      px += two_ry2
      if p < 0
        p += ry2 + px
      else
        y -= 1
        py -= two_rx2
        p += ry2 + px - py
      end
      plot_ellipse_points(cx, cy, x, y, rgb565, fill)
    end

    # Region 2
    p = (ry2 * (x + 0.5)**2 + rx2 * (y - 1)**2 - rx2 * ry2).round
    while y > 0
      y -= 1
      py -= two_rx2
      if p > 0
        p += rx2 - py
      else
        x += 1
        px += two_ry2
        p += rx2 - py + px
      end
      plot_ellipse_points(cx, cy, x, y, rgb565, fill)
    end
  end

  private

  def set_window(x0, y0, x1, y1)
    write_command(CMD_CASET, [(x0 >> 8) & 0xFF, x0 & 0xFF, (x1 >> 8) & 0xFF, x1 & 0xFF])
    write_command(CMD_RASET, [(y0 >> 8) & 0xFF, y0 & 0xFF, (y1 >> 8) & 0xFF, y1 & 0xFF])
  end

  # Begin RAMWR transaction, yield to block that writes pixel bytes via @spi,
  # then end transaction. Shared CS/DC pattern for fill / draw_rect / draw_pixel.
  def write_pixels
    @cs.write(0)
    @dc.write(0)
    @spi.write(CMD_RAMWR)
    @dc.write(1)
    yield
    @cs.write(1)
  end

  # Fill the address-window rectangle with one repeated RGB565 colour.
  # Uses 256-pair chunks so per-spi.write overhead is amortised — one DMA
  # transaction per chunk instead of one per pixel. The byte stream emitted
  # is identical to the per-pixel form.
  CHUNK_PAIRS = 256

  def fill_window(x0, y0, x1, y1, rgb565)
    set_window(x0, y0, x1, y1)
    hi = (rgb565 >> 8) & 0xFF
    lo = rgb565 & 0xFF
    chunk = [hi, lo] * CHUNK_PAIRS
    pair_count = (x1 - x0 + 1) * (y1 - y0 + 1)
    full_chunks, leftover_pairs = pair_count.divmod(CHUNK_PAIRS)
    write_pixels do
      full_chunks.times { @spi.write(chunk) }
      @spi.write([hi, lo] * leftover_pairs) if leftover_pairs > 0
    end
  end

  def plot_ellipse_points(cx, cy, dx, dy, rgb565, fill)
    if fill
      draw_line(cx - dx, cy + dy, cx + dx, cy + dy, rgb565)
      draw_line(cx - dx, cy - dy, cx + dx, cy - dy, rgb565)
    else
      draw_pixel(cx + dx, cy + dy, rgb565)
      draw_pixel(cx - dx, cy + dy, rgb565)
      draw_pixel(cx + dx, cy - dy, rgb565)
      draw_pixel(cx - dx, cy - dy, rgb565)
    end
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
    unless payload.empty?
      @dc.write(1)
      @spi.write(*payload)
    end
    @cs.write(1)
  end
end
