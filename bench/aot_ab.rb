# Interpreted Ruby vs the AOT kernels, on the VM tools/aot_host_vm.sh builds:
#
#   cat mrbgems/picoruby-aw88298/mrblib/aw88298.rb bench/aot_ab.rb > build/aot_ab.rb
#   build/host-aot/bin/picoruby build/aot_ab.rb
#
# Each pair is checked for equal bytes before it is timed. Microseconds per call.

def ulaw_decode_rb(src)
  out = "\0" * (src.bytesize * 2)
  i = 0
  while i < src.bytesize
    u = (~src.getbyte(i)) & 0xFF
    t = (((u & 0x0F) << 3) + 0x84) << ((u & 0x70) >> 4)
    v = ((u & 0x80) != 0 ? (0x84 - t) : (t - 0x84)) & 0xFFFF
    out.setbyte(i * 2, v & 0xFF)
    out.setbyte(i * 2 + 1, v >> 8)
    i += 1
  end
  out
end

# ILI9342#blit_glyph without the kernel: an Array of bytes per row.
def glyph_rb(w, rows, fg, bg)
  out = []
  y = 0
  while y < rows.size
    bytes = []
    bit = w - 1
    while bit >= 0
      c = ((rows[y] >> bit) & 1) == 1 ? fg : bg
      bytes << ((c >> 8) & 0xFF) << (c & 0xFF)
      bit -= 1
    end
    out << bytes
    y += 1
  end
  out
end

class Sink
  attr_reader :out
  def initialize; @out = ""; end
  def write(s); @out << s; end
end

def time_us(reps)
  t0 = Time.now.to_f
  reps.times { yield }
  ((Time.now.to_f - t0) * 1_000_000 / reps).round(1)
end

def report(label, a, b)
  puts "#{label}\tinterpreted #{a}\tAOT #{b}"
end

src = "\0" * 4096
i = 0
while i < src.bytesize
  src.setbyte(i, (i * 37) % 256)
  i += 1
end
raise "ulaw_decode differs" unless ulaw_decode(src) == ulaw_decode_rb(src)
report("ulaw_decode 4096 B", time_us(20) { ulaw_decode_rb(src) }, time_us(200) { ulaw_decode(src) })

sink = Sink.new
AW88298.new(i2c: nil, i2s: sink).play_ulaw(src * 4)
raise "play_ulaw differs" unless sink.out == ulaw_decode_rb(src * 4)
spk = AW88298.new(i2c: nil, i2s: Sink.new)
report("play_ulaw 16384 B (core 1)", time_us(5) { ulaw_decode_rb(src * 4) }, time_us(20) { spk.play_ulaw(src * 4) })

rows = []
16.times { |y| rows << ((y * 40503 + 12345) & 0xFFFF) }
flat = glyph_rb(16, rows, 0xFFFF, 0).flatten.pack("C*")
raise "glyph16 differs" unless glyph16(16, 0xFFFF, 0, *rows) == flat
report("glyph 16x16", time_us(400) { glyph_rb(16, rows, 0xFFFF, 0) }, time_us(400) { glyph16(16, 0xFFFF, 0, *rows) })
