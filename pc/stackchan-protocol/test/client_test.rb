require "test_helper"
require "stackchan_protocol"

class FaceTableTest < Test::Unit::TestCase
  def test_neutral_maps_to_zero
    assert_equal "0", StackchanProtocol::FACE_BYTES.fetch(:neutral)
  end

  def test_smile_maps_to_one
    assert_equal "1", StackchanProtocol::FACE_BYTES.fetch(:smile)
  end

  def test_joy_maps_to_two
    assert_equal "2", StackchanProtocol::FACE_BYTES.fetch(:joy)
  end

  def test_table_is_frozen
    assert_predicate StackchanProtocol::FACE_BYTES, :frozen?
  end

  def test_unknown_face_raises_key_error
    assert_raises(KeyError) { StackchanProtocol::FACE_BYTES.fetch(:rage) }
  end
end

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

class ClientInitializeTest < Test::Unit::TestCase
  def test_stores_port_and_baud
    client = StackchanProtocol::Client.new(port: "/dev/cu.fake")
    assert_equal "/dev/cu.fake", client.port
    assert_equal 115_200, client.baud
  end

  def test_accepts_custom_baud
    client = StackchanProtocol::Client.new(port: "/dev/cu.fake", baud: 9_600)
    assert_equal 9_600, client.baud
  end

  def test_default_ack_timeout
    client = StackchanProtocol::Client.new(port: "/dev/cu.fake")
    assert_equal 0.5, client.ack_timeout
  end
end

class ClientOpenTest < Test::Unit::TestCase
  def test_open_invokes_uart_class_with_port_and_baud
    fake_uart_class = Class.new do
      class << self
        attr_reader :opened_with
      end

      def self.open(port, baud)
        @opened_with = [port, baud]
        u = FakeUart.new
        block_given? ? yield(u).tap { u.close } : u
      end
    end

    client = StackchanProtocol::Client.new(
      port: "/dev/cu.fake", baud: 115_200, uart_class: fake_uart_class
    )
    client.open { |_serial| :ok }
    assert_equal ["/dev/cu.fake", 115_200], fake_uart_class.opened_with
  end

  def test_open_yields_serial_to_block
    fake_uart_class = Class.new do
      def self.open(_port, _baud)
        u = FakeUart.new
        yield u
      ensure
        u&.close
      end
    end

    captured = nil
    client = StackchanProtocol::Client.new(
      port: "/dev/cu.fake", uart_class: fake_uart_class
    )
    client.open { |serial| captured = serial }
    assert_kind_of FakeUart, captured
  end
end
