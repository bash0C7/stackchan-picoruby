class AW88298Test < Picotest::Test
  # ITU G.711 mu-law decode. Known vectors: 0xFF/0x7F -> 0, 0x00 -> -32124, 0x80 -> +32124.
  def test_ulaw_zero_codes
    assert_equal "\x00\x00", AW88298.ulaw_decode("\xFF")
    assert_equal "\x00\x00", AW88298.ulaw_decode("\x7F")
  end

  def test_ulaw_extremes
    assert_equal "\x84\x82", AW88298.ulaw_decode("\x00")  # -32124 -> 0x8284, LE 84 82
    assert_equal "\x7C\x7D", AW88298.ulaw_decode("\x80")  # +32124 -> 0x7D7C, LE 7C 7D
  end

  def test_ulaw_two_bytes_per_code
    # bytesize, not length: host PicoRuby VM mis-counts multibyte String#length
    assert_equal 6, AW88298.ulaw_decode("\x00\x80\xFF").bytesize
  end

  # AW88298 init writes (from M5Unified), 16-bit big-endian -> [reg, hi, lo] triples.
  def test_aw88298_init_writes_8khz
    seq = AW88298.aw88298_init_writes(8000)
    assert_equal [0x61, 0x06, 0x73], seq[0]
    assert_equal [0x04, 0x40, 0x40], seq[1]
    assert_equal [0x05, 0x00, 0x08], seq[2]
    assert_equal [0x06, 0x14, 0xC0], seq[3]   # 8 kHz -> reg0x06 = 0x14C0
    assert_equal [0x0C, 0x00, 0x64], seq[4]
  end

  def test_aw88298_reg06_16khz
    assert_equal 0x14C3, AW88298.aw88298_reg06(16000)
  end

  # Instance behaviour against host fakes (FakeI2C + FakeI2S via harness load_files).
  def test_init_amp_writes_registers_via_i2c
    i2c = FakeI2C.new
    spk = AW88298.new(i2c: i2c, i2s: I2S.new(sample_rate: 8000))
    spk.init_amp(8000)
    assert_equal 5, i2c.writes.length
    assert_equal [0x36, [0x61, 0x06, 0x73]], i2c.writes[0]
  end

  def test_play_ulaw_feeds_decoded_pcm_to_i2s
    spk = AW88298.new(i2c: FakeI2C.new, i2s: I2S.new(sample_rate: 8000))
    spk.play_ulaw("\x00\x80")   # 2 mu-law codes -> 4 bytes of int16 PCM
    assert_equal 4, spk.i2s.written.bytesize
  end
end
