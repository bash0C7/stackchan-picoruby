# A/B of the AOT kernels (aot/kernels/stackchan_aot.rb) against the interpreted
# bodies and the C gem, on whichever picoruby runs it. Each variant is checked
# against the interpreted result before it is timed.
#
#   <picoruby> bench/aot_ab.rb          # interpreted + whatever the VM carries
#
# The VM from tools/aot_host_vm.sh carries the AOT kernels; the host picotest VM
# carries AW88298 (C). Timings are wall-clock per call, host-only numbers.

def ulaw_sample_rb(b)
  u = (~b) & 0xFF
  t = ((u & 0x0F) << 3) + 0x84
  t = t << ((u & 0x70) >> 4)
  (u & 0x80) != 0 ? (0x84 - t) : (t - 0x84)
end

def ulaw_decode_rb(src)
  n = src.bytesize
  out = "\0" * (n * 2)
  i = 0
  while i < n
    v = ulaw_sample_rb(src.getbyte(i)) & 0xFFFF
    out.setbyte(i * 2, v & 0xFF)
    out.setbyte(i * 2 + 1, v >> 8)
    i += 1
  end
  out
end

# ILI9342#blit_glyph's inner loop as shipped: an Array of bytes per row.
def glyph_rows_array(spi, w, rows, fg, bg)
  fg_hi = (fg >> 8) & 0xFF; fg_lo = fg & 0xFF
  bg_hi = (bg >> 8) & 0xFF; bg_lo = bg & 0xFF
  row_i = 0
  while row_i < rows.size
    row = rows[row_i]
    bytes = []
    bit = w - 1
    while bit >= 0
      if ((row >> bit) & 1) == 1
        bytes << fg_hi << fg_lo
      else
        bytes << bg_hi << bg_lo
      end
      bit -= 1
    end
    spi.write(bytes)
    row_i += 1
  end
end

def glyph_rows_aot(spi, w, rows, fg, bg)
  i = 0
  while i < rows.size
    spi.write(glyph_row(rows[i], w, fg, bg))
    i += 1
  end
end

def glyph16_aot(spi, w, r, fg, bg)
  spi.write(glyph16(w, fg, bg, r[0], r[1], r[2], r[3], r[4], r[5], r[6], r[7],
                    r[8], r[9], r[10], r[11], r[12], r[13], r[14], r[15]))
end

# Collects what blit sends, so every variant's bytes can be compared.
class CaptureSpi
  attr_reader :out
  def initialize; @out = ""; end
  def write(x)
    if x.is_a?(String)
      @out << x
    else
      i = 0
      while i < x.size
        @out << x[i].chr
        i += 1
      end
    end
  end
end

class NullSpi
  def write(_x); end
end

def bytes_input(n, nul_free)
  s = "\x01" * n
  i = 0
  while i < n
    v = (i * 37) % 256
    v = 1 if nul_free && v == 0
    s.setbyte(i, v)
    i += 1
  end
  s
end

def time_us(reps)
  t0 = Time.now.to_f
  i = 0
  while i < reps
    yield
    i += 1
  end
  (Time.now.to_f - t0) * 1_000_000 / reps
end

def row(label, us)
  puts "#{label}\t#{(us * 100).round / 100.0}"
end

aot = respond_to?(:glyph_row, true)
c_gem = Object.const_defined?(:AW88298) && AW88298.respond_to?(:ulaw_decode)

[180, 4096].each do |n|
  src = bytes_input(n, false)
  ref = ulaw_decode_rb(src)
  reps = n == 180 ? 2000 : 200
  row("ulaw n=#{n} interpreted", time_us(reps / 10) { ulaw_decode_rb(src) })
  if c_gem
    raise "C ulaw mismatch" unless AW88298.ulaw_decode(src) == ref
    row("ulaw n=#{n} C", time_us(reps) { AW88298.ulaw_decode(src) })
  end
  if aot
    # The suppify binding takes String arguments NUL-terminated, so a 0x00
    # byte cannot reach the kernel; time it on NUL-free input.
    free = bytes_input(n, true)
    raise "AOT ulaw mismatch" unless ulaw_decode(free) == ulaw_decode_rb(free)
    row("ulaw n=#{n} AOT (NUL-free input)", time_us(reps) { ulaw_decode(free) })
  end
end

rows = []
i = 0
while i < 16
  rows << ((i * 40503 + 12345) & 0xFFFF)
  i += 1
end
fg = 0xFFFF
bg = 0x0000
ref = CaptureSpi.new
glyph_rows_array(ref, 16, rows, fg, bg)
if aot
  cap = CaptureSpi.new
  glyph_rows_aot(cap, 16, rows, fg, bg)
  raise "AOT glyph_row mismatch" unless cap.out == ref.out
  cap = CaptureSpi.new
  glyph16_aot(cap, 16, rows, fg, bg)
  raise "AOT glyph16 mismatch" unless cap.out == ref.out
end
spi = NullSpi.new
row("glyph 16x16 array (shipped)", time_us(400) { glyph_rows_array(spi, 16, rows, fg, bg) })
if aot
  row("glyph 16x16 AOT glyph_row x16", time_us(400) { glyph_rows_aot(spi, 16, rows, fg, bg) })
  row("glyph 16x16 AOT glyph16 x1", time_us(400) { glyph16_aot(spi, 16, rows, fg, bg) })
end
