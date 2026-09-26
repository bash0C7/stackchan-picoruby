# Compiled ahead of time by spinel -> suppify. Types are inline RBS on each
# public def.

private

def ulaw_sample(b)
  u = (~b) & 0xFF
  t = ((u & 0x0F) << 3) + 0x84
  t = t << ((u & 0x70) >> 4)
  (u & 0x80) != 0 ? (0x84 - t) : (t - 0x84)
end

public

# G.711 mu-law -> little-endian signed 16-bit PCM.
#: (String) -> String
def ulaw_decode(src)
  n = src.bytesize
  out = "\0".b * (n * 2)
  i = 0
  while i < n
    v = ulaw_sample(src.getbyte(i)) & 0xFFFF
    out.setbyte(i * 2, v & 0xFF)
    out.setbyte(i * 2 + 1, v >> 8)
    i += 1
  end
  out
end

# One 16-row glyph as RGB565 big-endian pixels: fg where a bit is set, the
# row's MSB (of w bits) leftmost. Rows come as 16 Integers: an Array cannot
# cross the suppify boundary.
#: (Integer, Integer, Integer, Integer, Integer, Integer, Integer, Integer, Integer, Integer, Integer, Integer, Integer, Integer, Integer, Integer, Integer, Integer, Integer) -> String
def glyph16(w, fg, bg, r0, r1, r2, r3, r4, r5, r6, r7, r8, r9, r10, r11, r12, r13, r14, r15)
  rows = [r0, r1, r2, r3, r4, r5, r6, r7, r8, r9, r10, r11, r12, r13, r14, r15]
  out = "\0".b * (w * 32)
  j = 0
  y = 0
  while y < 16
    bit = w - 1
    while bit >= 0
      c = ((rows[y] >> bit) & 1) == 1 ? fg : bg
      out.setbyte(j, (c >> 8) & 0xFF)
      out.setbyte(j + 1, c & 0xFF)
      j += 2
      bit -= 1
    end
    y += 1
  end
  out
end
