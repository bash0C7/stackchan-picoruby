require "test_helper"

class FakeUartHarnessTest < Test::Unit::TestCase
  def test_write_records_history
    u = FakeUart.new
    u.write("1")
    assert_equal ["1"], u.writes
  end

  def test_read_returns_buffered_bytes
    u = FakeUart.new(read_bytes: "?X")
    assert_equal "?", u.read(1)
    assert_equal "X", u.read(1)
    assert_nil u.read(1)
  end

  def test_wait_readable_returns_self_when_buffer_nonempty
    u = FakeUart.new(read_bytes: "?")
    assert_same u, u.wait_readable(0.5)
  end

  def test_wait_readable_returns_nil_on_empty_buffer
    u = FakeUart.new
    assert_nil u.wait_readable(0.5)
  end

  def test_wait_readable_records_timeout_arg
    u = FakeUart.new(read_bytes: "?")
    u.wait_readable(0.42)
    assert_equal [0.42], u.wait_readable_calls
  end

  def test_close_marks_closed
    u = FakeUart.new
    u.close
    assert u.closed?
  end
end
