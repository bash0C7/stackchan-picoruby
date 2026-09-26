class AW88298Test < Picotest::Test
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

  def test_init_amp_writes_registers_via_i2c
    i2c = FakeI2C.new
    spk = AW88298.new(i2c: i2c, i2s: I2S.new(sample_rate: 8000))
    spk.init_amp(8000)
    assert_equal 5, i2c.writes.length
    assert_equal [0x36, [0x61, 0x06, 0x73]], i2c.writes[0]
  end

  def clip(n)
    s = "\0" * n
    i = 0
    while i < n
      s.setbyte(i, (i * 37) % 256)
      i += 1
    end
    s
  end

  # Binary Strings in a failure message break picotest's JSON report; compare hex.
  def hex(s)
    s.unpack("H*")[0]
  end

  def test_play_ulaw_writes_every_chunk_decoded_in_order
    c = clip(AW88298::CHUNK * 2 + 10)
    spk = AW88298.new(i2c: FakeI2C.new, i2s: I2S.new(sample_rate: 8000))
    Multicore.log.clear
    spk.play_ulaw(c)
    assert_equal hex(ulaw_decode(c)), hex(spk.i2s.written)
    assert_equal [AW88298::CHUNK, AW88298::CHUNK, 10], Multicore.log.map { |e| e[2] }
  end

  class OrderI2S
    def write(pcm)
      Multicore.log << [:write, pcm.bytesize]
    end
  end

  def test_the_next_chunk_is_spawned_before_the_previous_one_is_written
    Multicore.log.clear
    AW88298.new(i2c: FakeI2C.new, i2s: OrderI2S.new).play_ulaw(clip(AW88298::CHUNK + 1))
    assert_equal [[:spawn, :ulaw_decode, AW88298::CHUNK], [:spawn, :ulaw_decode, 1],
                  [:write, AW88298::CHUNK * 2], [:write, 2]], Multicore.log
  end
end
