# Records the sequence of draw calls made on a display instance.
# Each entry is [method_symbol, args_array].
class FakeDisplay
  attr_reader :calls

  def initialize
    @calls = []
    @raise_on_fill = nil
  end

  # When set to a truthy exception class/instance, the next #fill call raises it.
  attr_accessor :raise_on_fill

  def fill(color)
    raise @raise_on_fill if @raise_on_fill
    @calls << [:fill, [color]]
    nil
  end

  def draw_ellipse(cx, cy, rx, ry, color, fill: false)
    @calls << [:draw_ellipse, [cx, cy, rx, ry, color, { fill: fill }]]
    nil
  end

  def draw_line(x0, y0, x1, y1, color)
    @calls << [:draw_line, [x0, y0, x1, y1, color]]
    nil
  end

  def draw_rect(x, y, w, h, color, fill: false)
    @calls << [:draw_rect, [x, y, w, h, color, { fill: fill }]]
    nil
  end

  def draw_text(x, y, text, font: "go16", scale: 1, fg: 0xFFFF, bg: 0x0000)
    @calls << [:draw_text, [x, y, text, { font: font, scale: scale, fg: fg, bg: bg }]]
    nil
  end
end
