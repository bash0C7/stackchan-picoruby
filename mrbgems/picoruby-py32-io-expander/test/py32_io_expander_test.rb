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
  def test_writes_count_to_REG_LED_CFG
    # Official firmware writes the count into LED_CFG (0x24), masked to 6 bits.
    i2c = FakeI2C.new
    py32 = PY32IOExpander.new(i2c)
    py32.set_led_count(12)
    w = i2c.writes.first
    assert_equal 0x6F, w[:addr]
    assert_equal [0x24, 12], w[:args]
  end

  def test_masks_count_to_6_bits
    i2c = FakeI2C.new
    py32 = PY32IOExpander.new(i2c)
    py32.set_led_count(0xFF)
    assert_equal [0x24, 0x3F], i2c.writes.first[:args]
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

  def test_packs_red_to_rgb565_low_byte_first
    # red 255 -> r5=0x1F=11111, g6=0, b5=0
    # RGB565 = 11111000 00000000 = 0xF800 -> little-endian bytes [0x00, 0xF8]
    i2c = FakeI2C.new
    py32 = PY32IOExpander.new(i2c)
    py32.write_led_ram([[255, 0, 0]])
    args = i2c.writes.first[:args]
    assert_equal [0x30, 0x00, 0xF8], args
  end

  def test_packs_green_to_rgb565_little_endian
    # green 255 -> r5=0, g6=0x3F=111111, b5=0
    # RGB565 = 00000111 11100000 = 0x07E0 -> little-endian [0xE0, 0x07]
    i2c = FakeI2C.new
    py32 = PY32IOExpander.new(i2c)
    py32.write_led_ram([[0, 255, 0]])
    args = i2c.writes.first[:args]
    assert_equal [0x30, 0xE0, 0x07], args
  end

  def test_packs_blue_to_rgb565_little_endian
    # blue 255 -> r5=0, g6=0, b5=0x1F
    # RGB565 = 00000000 00011111 = 0x001F -> little-endian [0x1F, 0x00]
    i2c = FakeI2C.new
    py32 = PY32IOExpander.new(i2c)
    py32.write_led_ram([[0, 0, 255]])
    args = i2c.writes.first[:args]
    assert_equal [0x30, 0x1F, 0x00], args
  end

  def test_packs_white_full_intensity
    # white 255,255,255 -> r5=0x1F, g6=0x3F, b5=0x1F
    # RGB565 = 11111111 11111111 = 0xFFFF -> [0xFF, 0xFF] (endian-agnostic)
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
    # red LE [0x00, 0xF8], green LE [0xE0, 0x07]
    assert_equal [0x30, 0x00, 0xF8, 0xE0, 0x07], args
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

class PY32RefreshLedsTest < Test::Unit::TestCase
  # Per StackChan-BSP src/drivers/PY32IOExpander/PY32IOExpander.cpp:275-279,
  # refresh must read REG_LED_CFG then OR-in bit 6 so the LED count (bits 5:0)
  # written by set_led_count is preserved. Plain write of 0x40 would zero the
  # count and the chip would emit nothing on the WS2812 line.
  def test_reads_REG_LED_CFG_then_writes_with_bit6_set
    i2c = FakeI2C.new
    i2c.queue_read("\x0C".b)  # count=12 already set
    py32 = PY32IOExpander.new(i2c)
    py32.refresh_leds
    assert_equal 1, i2c.reads.size, "must read REG_LED_CFG before writing"
    assert_equal 0x24, i2c.reads.first[:reg]
    w = i2c.writes.first
    assert_equal 0x6F, w[:addr]
    assert_equal [0x24, 0x4C], w[:args], "preserves count 0x0C + bit6 -> 0x4C"
  end

  def test_writes_only_bit6_when_count_is_zero
    # Default queue returns 0x00, so result must be 0x40.
    i2c = FakeI2C.new
    py32 = PY32IOExpander.new(i2c)
    py32.refresh_leds
    assert_equal [0x24, 0x40], i2c.writes.first[:args]
  end
end

class PY32SetDirectionTest < Test::Unit::TestCase
  def test_pin_lt_8_sets_bit_in_REG_GPIO_M_L
    # initial reg is 0x00 (FakeI2C returns zeros), set_direction(3, true) -> 0x08
    i2c = FakeI2C.new
    py32 = PY32IOExpander.new(i2c)
    py32.set_direction(3, true)
    assert_equal 1, i2c.reads.size
    assert_equal 0x03, i2c.reads.first[:reg]
    w = i2c.writes.first
    assert_equal [0x03, 0x08], w[:args]
  end

  def test_pin_13_sets_bit_5_in_REG_GPIO_M_H
    # pin 13 -> reg_h, bit = 13 - 8 = 5 -> 0x20
    i2c = FakeI2C.new
    py32 = PY32IOExpander.new(i2c)
    py32.set_direction(13, true)
    assert_equal 0x04, i2c.reads.first[:reg]
    assert_equal [0x04, 0x20], i2c.writes.first[:args]
  end

  def test_set_direction_false_clears_bit
    # initial value 0xFF -> clearing bit 5 -> 0xDF
    i2c = FakeI2C.new
    i2c.queue_read("\xFF".b)
    py32 = PY32IOExpander.new(i2c)
    py32.set_direction(13, false)
    assert_equal [0x04, 0xDF], i2c.writes.first[:args]
  end

  def test_read_modify_write_preserves_other_bits
    # initial value 0x05 (bits 0 and 2 set), set bit 5 -> 0x25
    i2c = FakeI2C.new
    i2c.queue_read("\x05".b)
    py32 = PY32IOExpander.new(i2c)
    py32.set_direction(13, true)
    assert_equal [0x04, 0x25], i2c.writes.first[:args]
  end
end

class PY32SetPullModeTest < Test::Unit::TestCase
  def test_pull_up_clears_pd_then_sets_pu_for_pin_13
    # pin 13 -> reg_h variants. Initial regs are 0x00.
    # Sequence: clear PD_H bit 5 -> set PU_H bit 5.
    i2c = FakeI2C.new
    py32 = PY32IOExpander.new(i2c)
    py32.set_pull_mode(13, true)
    assert_equal 2, i2c.writes.size
    # First: write to REG_GPIO_PD_H (0x0C), clearing bit 5 from 0x00 -> 0x00
    assert_equal [0x0C, 0x00], i2c.writes[0][:args]
    # Second: write to REG_GPIO_PU_H (0x0A), setting bit 5 -> 0x20
    assert_equal [0x0A, 0x20], i2c.writes[1][:args]
  end

  def test_pull_down_clears_pu_then_sets_pd_for_pin_13
    i2c = FakeI2C.new
    py32 = PY32IOExpander.new(i2c)
    py32.set_pull_mode(13, false)
    assert_equal 2, i2c.writes.size
    assert_equal [0x0A, 0x00], i2c.writes[0][:args]
    assert_equal [0x0C, 0x20], i2c.writes[1][:args]
  end

  def test_pull_up_uses_low_regs_for_pin_lt_8
    # pin 3 -> reg_l variants (PD_L=0x0B, PU_L=0x09), bit 3 -> 0x08
    i2c = FakeI2C.new
    py32 = PY32IOExpander.new(i2c)
    py32.set_pull_mode(3, true)
    assert_equal [0x0B, 0x00], i2c.writes[0][:args]
    assert_equal [0x09, 0x08], i2c.writes[1][:args]
  end
end

class PY32SetDriveModeTest < Test::Unit::TestCase
  def test_push_pull_clears_bit_for_pin_13
    # open_drain=false -> clear bit 5 of REG_GPIO_DRV_H (0x14). initial 0x00 -> 0x00
    i2c = FakeI2C.new
    py32 = PY32IOExpander.new(i2c)
    py32.set_drive_mode(13, false)
    assert_equal 0x14, i2c.reads.first[:reg]
    assert_equal [0x14, 0x00], i2c.writes.first[:args]
  end

  def test_open_drain_sets_bit_for_pin_13
    i2c = FakeI2C.new
    py32 = PY32IOExpander.new(i2c)
    py32.set_drive_mode(13, true)
    assert_equal [0x14, 0x20], i2c.writes.first[:args]
  end

  def test_push_pull_preserves_other_bits
    # initial 0xFF, clear bit 5 -> 0xDF
    i2c = FakeI2C.new
    i2c.queue_read("\xFF".b)
    py32 = PY32IOExpander.new(i2c)
    py32.set_drive_mode(13, false)
    assert_equal [0x14, 0xDF], i2c.writes.first[:args]
  end

  def test_pin_lt_8_uses_DRV_L
    i2c = FakeI2C.new
    py32 = PY32IOExpander.new(i2c)
    py32.set_drive_mode(2, true)
    assert_equal [0x13, 0x04], i2c.writes.first[:args]
  end
end
