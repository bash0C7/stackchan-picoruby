# The kernels as plain Ruby: what spinel compiles is checked here first.
class StackchanAotTest < Picotest::Test
  # All 256 codes as ITU-T G.711 decodes them (the C decoder's output).
  ULAW_ALL_PCM_HEX =
    "84828486848a848e84928496849a849e84a284a684aa84ae84b284b684ba84be" \
    "84c184c384c584c784c984cb84cd84cf84d184d384d584d784d984db84dd84df" \
    "04e104e204e304e404e504e604e704e804e904ea04eb04ec04ed04ee04ef04f0" \
    "c4f044f1c4f144f2c4f244f3c4f344f4c4f444f5c4f544f6c4f644f7c4f744f8" \
    "a4f8e4f824f964f9a4f9e4f924fa64faa4fae4fa24fb64fba4fbe4fb24fc64fc" \
    "94fcb4fcd4fcf4fc14fd34fd54fd74fd94fdb4fdd4fdf4fd14fe34fe54fe74fe" \
    "8cfe9cfeacfebcfeccfedcfeecfefcfe0cff1cff2cff3cff4cff5cff6cff7cff" \
    "88ff90ff98ffa0ffa8ffb0ffb8ffc0ffc8ffd0ffd8ffe0ffe8fff0fff8ff0000" \
    "7c7d7c797c757c717c6d7c697c657c617c5d7c597c557c517c4d7c497c457c41" \
    "7c3e7c3c7c3a7c387c367c347c327c307c2e7c2c7c2a7c287c267c247c227c20" \
    "fc1efc1dfc1cfc1bfc1afc19fc18fc17fc16fc15fc14fc13fc12fc11fc10fc0f" \
    "3c0fbc0e3c0ebc0d3c0dbc0c3c0cbc0b3c0bbc0a3c0abc093c09bc083c08bc07" \
    "5c071c07dc069c065c061c06dc059c055c051c05dc049c045c041c04dc039c03" \
    "6c034c032c030c03ec02cc02ac028c026c024c022c020c02ec01cc01ac018c01" \
    "74016401540144013401240114010401f400e400d400c400b400a40094008400" \
    "7800700068006000580050004800400038003000280020001800100008000000"

  def all_codes
    s = "\0" * 256
    i = 0
    while i < 256
      s.setbyte(i, i)
      i += 1
    end
    s
  end

  def hex(s)
    s.unpack("H*")[0]
  end

  def test_ulaw_decode_matches_g711_for_every_code
    assert_equal ULAW_ALL_PCM_HEX, hex(ulaw_decode(all_codes))
  end

  def test_ulaw_decode_known_vectors
    assert_equal "0000", hex(ulaw_decode("\xFF"))
    assert_equal "8482", hex(ulaw_decode("\x00"))   # -32124
    assert_equal "7c7d", hex(ulaw_decode("\x80"))   # +32124
  end

  def test_glyph16_is_msb_first_fg_where_set_big_endian
    rows = [0b1000000000000001] + [0] * 15
    cell = glyph16(16, 0xF800, 0x001F, *rows)
    assert_equal 512, cell.bytesize
    assert_equal "f800" + "001f" * 14 + "f800", hex(cell.byteslice(0, 32))
    assert_equal "001f" * 16, hex(cell.byteslice(32, 32))
  end
end
