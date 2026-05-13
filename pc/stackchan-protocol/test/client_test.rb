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

class ClientRawSendTest < Test::Unit::TestCase
  def setup
    @fake_uart = FakeUart.new
    @fake_uart_class = stub_uart_class(@fake_uart)
    @client = StackchanProtocol::Client.new(
      port: "/dev/cu.fake", uart_class: @fake_uart_class
    )
  end

  def test_raw_send_writes_single_byte
    @client.open do |serial|
      @client.raw_send(serial, "9")
    end
    assert_equal ["9"], @fake_uart.writes
  end

  private

  def stub_uart_class(fake)
    Class.new do
      define_singleton_method(:open) do |_port, _baud, &block|
        block.call(fake)
      end
    end
  end
end

class ClientSetFaceSuccessTest < Test::Unit::TestCase
  def setup
    @fake_uart = FakeUart.new
    @fake_uart_class = Class.new do
      def self.open(_port, _baud, &block); block.call(@_fake); end
      class << self; attr_accessor :_fake; end
    end
    @fake_uart_class._fake = @fake_uart
    @client = StackchanProtocol::Client.new(
      port: "/dev/cu.fake", ack_timeout: 0.1, uart_class: @fake_uart_class
    )
  end

  def test_set_face_writes_smile_byte
    @client.open { |s| @client.set_face(s, :smile) }
    assert_equal ["1"], @fake_uart.writes
  end

  def test_set_face_writes_neutral_byte
    @client.open { |s| @client.set_face(s, :neutral) }
    assert_equal ["0"], @fake_uart.writes
  end

  def test_set_face_writes_joy_byte
    @client.open { |s| @client.set_face(s, :joy) }
    assert_equal ["2"], @fake_uart.writes
  end

  def test_set_face_returns_nil_on_ack_timeout
    result = @client.open { |s| @client.set_face(s, :smile) }
    assert_nil result
  end

  def test_set_face_uses_configured_ack_timeout
    @client.open { |s| @client.set_face(s, :smile) }
    assert_equal [0.1], @fake_uart.wait_readable_calls
  end
end

class ClientSetFaceDeviceErrorTest < Test::Unit::TestCase
  def setup
    @fake_uart = FakeUart.new(read_bytes: "?")
    @fake_uart_class = Class.new do
      def self.open(_port, _baud, &block); block.call(@_fake); end
      class << self; attr_accessor :_fake; end
    end
    @fake_uart_class._fake = @fake_uart
    @client = StackchanProtocol::Client.new(
      port: "/dev/cu.fake", ack_timeout: 0.1, uart_class: @fake_uart_class
    )
  end

  def test_set_face_raises_device_error_on_question_mark
    assert_raises(StackchanProtocol::DeviceError) do
      @client.open { |s| @client.set_face(s, :smile) }
    end
  end

  def test_set_face_consumes_byte_before_raising
    begin
      @client.open { |s| @client.set_face(s, :smile) }
    rescue StackchanProtocol::DeviceError
      # expected
    end
    assert_empty @fake_uart.read_buffer
  end

  def test_set_face_ignores_non_question_noise
    @fake_uart.read_buffer = "X"
    result = nil
    assert_nothing_raised do
      result = @client.open { |s| @client.set_face(s, :smile) }
    end
    assert_nil result
  end
end
