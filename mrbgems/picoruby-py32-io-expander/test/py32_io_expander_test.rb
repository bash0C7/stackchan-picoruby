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
