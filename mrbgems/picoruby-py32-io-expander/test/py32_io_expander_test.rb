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
