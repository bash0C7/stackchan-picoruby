require "test_helper"

class FakeI2CHarnessTest < Test::Unit::TestCase
  def test_write_records_call
    i2c = FakeI2C.new
    i2c.write(0x6F, 0x24, 0x40)
    assert_equal 1, i2c.writes.size
    assert_equal 0x6F, i2c.writes.first[:addr]
    assert_equal [0x24, 0x40], i2c.writes.first[:args]
  end

  def test_write_returns_args_count_by_default
    i2c = FakeI2C.new
    result = i2c.write(0x6F, 0x24, 0x40, 0x55)
    assert_equal 3, result
  end

  def test_write_returns_override_when_set
    i2c = FakeI2C.new
    i2c.write_returns = 0
    assert_equal 0, i2c.write(0x6F, 0x24)
  end

  def test_read_serves_queued_bytes
    i2c = FakeI2C.new
    i2c.queue_read("\x12".b)
    assert_equal "\x12".b, i2c.read(0x6F, 1, 0x24)
  end

  def test_read_returns_zeros_when_queue_empty
    i2c = FakeI2C.new
    bytes = i2c.read(0x6F, 3, 0x00)
    assert_equal "\x00\x00\x00".b, bytes.b
  end
end

class PY32WriteRegTest < Test::Unit::TestCase
  def test_write_reg_sends_addr_reg_then_data
    i2c = FakeI2C.new
    py32 = PY32IOExpander.new(i2c)
    py32.send(:write_reg, 0x24, 0x40)
    w = i2c.writes.first
    assert_equal 0x6F, w[:addr]
    assert_equal [0x24, 0x40], w[:args]
  end

  def test_write_reg_passes_timeout
    i2c = FakeI2C.new
    py32 = PY32IOExpander.new(i2c)
    py32.send(:write_reg, 0x24, 0x40)
    assert_equal 1000, i2c.writes.first[:opts][:timeout]
  end

  def test_write_reg_raises_io_error_when_returns_zero
    i2c = FakeI2C.new
    i2c.write_returns = 0
    py32 = PY32IOExpander.new(i2c)
    assert_raises(IOError) { py32.send(:write_reg, 0x24, 0x40) }
  end
end

class PY32ReadRegTest < Test::Unit::TestCase
  def test_read_reg_returns_byte_array
    i2c = FakeI2C.new
    i2c.queue_read("\x42\x55".b)
    py32 = PY32IOExpander.new(i2c)
    bytes = py32.send(:read_reg, 0x10, 2)
    assert_equal [0x42, 0x55], bytes
  end

  def test_read_reg_raises_io_error_when_nil
    i2c = FakeI2C.new
    def i2c.read(*); nil; end
    py32 = PY32IOExpander.new(i2c)
    assert_raises(IOError) { py32.send(:read_reg, 0x10, 1) }
  end

  def test_read_reg_raises_io_error_when_empty
    i2c = FakeI2C.new
    def i2c.read(*); ""; end
    py32 = PY32IOExpander.new(i2c)
    assert_raises(IOError) { py32.send(:read_reg, 0x10, 1) }
  end
end

class PY32SetLedCountTest < Test::Unit::TestCase
  def test_writes_count_to_REG_LED_COUNT
    i2c = FakeI2C.new
    py32 = PY32IOExpander.new(i2c)
    py32.set_led_count(12)
    w = i2c.writes.first
    assert_equal 0x6F, w[:addr]
    assert_equal [0x25, 12], w[:args]
  end
end

class PY32WriteLedRamTest < Test::Unit::TestCase
  def test_writes_to_REG_LED_RAM_START
    i2c = FakeI2C.new
    py32 = PY32IOExpander.new(i2c)
    py32.write_led_ram([[255, 0, 0]])
    w = i2c.writes.first
    assert_equal 0x6F, w[:addr]
    assert_equal 0x30, w[:args].first
  end

  def test_packs_red_to_rgb565_high_byte_first
    # red 255 -> r5=0x1F=11111, g6=0, b5=0
    # RGB565 = 11111000 00000000 = 0xF800 -> bytes [0xF8, 0x00]
    i2c = FakeI2C.new
    py32 = PY32IOExpander.new(i2c)
    py32.write_led_ram([[255, 0, 0]])
    args = i2c.writes.first[:args]
    assert_equal [0x30, 0xF8, 0x00], args
  end

  def test_packs_green_to_rgb565
    # green 255 -> r5=0, g6=0x3F=111111, b5=0
    # RGB565 = 00000111 11100000 = 0x07E0 -> [0x07, 0xE0]
    i2c = FakeI2C.new
    py32 = PY32IOExpander.new(i2c)
    py32.write_led_ram([[0, 255, 0]])
    args = i2c.writes.first[:args]
    assert_equal [0x30, 0x07, 0xE0], args
  end

  def test_packs_blue_to_rgb565
    # blue 255 -> r5=0, g6=0, b5=0x1F
    # RGB565 = 00000000 00011111 = 0x001F -> [0x00, 0x1F]
    i2c = FakeI2C.new
    py32 = PY32IOExpander.new(i2c)
    py32.write_led_ram([[0, 0, 255]])
    args = i2c.writes.first[:args]
    assert_equal [0x30, 0x00, 0x1F], args
  end

  def test_packs_white_full_intensity
    # white 255,255,255 -> r5=0x1F, g6=0x3F, b5=0x1F
    # RGB565 = 11111111 11111111 = 0xFFFF -> [0xFF, 0xFF]
    i2c = FakeI2C.new
    py32 = PY32IOExpander.new(i2c)
    py32.write_led_ram([[255, 255, 255]])
    args = i2c.writes.first[:args]
    assert_equal [0x30, 0xFF, 0xFF], args
  end

  def test_writes_multiple_pixels_in_one_bulk_call
    i2c = FakeI2C.new
    py32 = PY32IOExpander.new(i2c)
    py32.write_led_ram([[255, 0, 0], [0, 255, 0]])
    assert_equal 1, i2c.writes.size, "must be one bulk I2C transaction"
    args = i2c.writes.first[:args]
    assert_equal [0x30, 0xF8, 0x00, 0x07, 0xE0], args
  end

  def test_handles_12_pixels
    i2c = FakeI2C.new
    py32 = PY32IOExpander.new(i2c)
    pixels = Array.new(12) { [255, 255, 255] }
    py32.write_led_ram(pixels)
    args = i2c.writes.first[:args]
    # 1 reg byte + 12 pixels * 2 bytes = 25 bytes
    assert_equal 25, args.size
    assert_equal 0x30, args.first
  end
end
