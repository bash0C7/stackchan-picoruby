# AOT kernels (spinel -> suppify). Plain Ruby: CRuby runs it as is, and the
# interpreted A/B baseline in bench/aot_ab.rb has the same bodies.
# Types for suppify are in stackchan_aot.rbs.

private

def ulaw_sample(b)
  u = (~b) & 0xFF
  t = ((u & 0x0F) << 3) + 0x84
  t = t << ((u & 0x70) >> 4)
  (u & 0x80) != 0 ? (0x84 - t) : (t - 0x84)
end

public

# G.711 mu-law -> little-endian signed 16-bit PCM (AW88298.ulaw_decode).
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

# RGB565 big-endian pixels of one glyph row, fg where the bit is set, MSB of the
# w bits leftmost (ILI9342#blit_glyph's inner loop).
def glyph_row(row, w, fg, bg)
  out = "\0".b * (w * 2)
  fh = (fg >> 8) & 0xFF
  fl = fg & 0xFF
  bh = (bg >> 8) & 0xFF
  bl = bg & 0xFF
  bit = w - 1
  j = 0
  while bit >= 0
    if ((row >> bit) & 1) == 1
      out.setbyte(j, fh)
      out.setbyte(j + 1, fl)
    else
      out.setbyte(j, bh)
      out.setbyte(j + 1, bl)
    end
    j += 2
    bit -= 1
  end
  out
end

# A whole 16-row glyph cell in one call. The rows come as 16 Integers because
# an Array cannot cross the suppify boundary.
def glyph16(w, fg, bg, r0, r1, r2, r3, r4, r5, r6, r7, r8, r9, r10, r11, r12, r13, r14, r15)
  glyph_row(r0, w, fg, bg) + glyph_row(r1, w, fg, bg) + glyph_row(r2, w, fg, bg) + glyph_row(r3, w, fg, bg) +
    glyph_row(r4, w, fg, bg) + glyph_row(r5, w, fg, bg) + glyph_row(r6, w, fg, bg) + glyph_row(r7, w, fg, bg) +
    glyph_row(r8, w, fg, bg) + glyph_row(r9, w, fg, bg) + glyph_row(r10, w, fg, bg) + glyph_row(r11, w, fg, bg) +
    glyph_row(r12, w, fg, bg) + glyph_row(r13, w, fg, bg) + glyph_row(r14, w, fg, bg) + glyph_row(r15, w, fg, bg)
end
