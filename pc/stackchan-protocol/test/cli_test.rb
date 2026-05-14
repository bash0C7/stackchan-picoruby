require "test_helper"
require "stackchan_protocol/cli"

class CliArgParsingTest < Test::Unit::TestCase
  def setup
    @fake_uart = FakeUart.new
    @fake_uart_class = Class.new do
      def self.open(_port, _baud, &block); block.call(@_fake); end
      class << self; attr_accessor :_fake; end
    end
    @fake_uart_class._fake = @fake_uart
    @stderr = StringIO.new
  end

  def test_port_from_argv
    StackchanProtocol::CLI.run(
      ["--port", "/dev/cu.test", "neutral"],
      env: {}, uart_class: @fake_uart_class, stderr: @stderr
    )
    assert_equal ["<F:0>\n"], @fake_uart.writes
  end

  def test_port_from_env_when_not_in_argv
    StackchanProtocol::CLI.run(
      ["smile"],
      env: { "STACKCHAN_PORT" => "/dev/cu.fromenv" },
      uart_class: @fake_uart_class, stderr: @stderr
    )
    assert_equal ["<F:1>\n"], @fake_uart.writes
  end

  def test_missing_port_exits_nonzero
    status = StackchanProtocol::CLI.run(
      ["smile"], env: {}, uart_class: @fake_uart_class, stderr: @stderr
    )
    assert_not_equal 0, status
    assert_match(/port/i, @stderr.string)
  end

  def test_missing_command_exits_nonzero
    status = StackchanProtocol::CLI.run(
      ["--port", "/dev/cu.test"],
      env: {}, uart_class: @fake_uart_class, stderr: @stderr
    )
    assert_not_equal 0, status
  end
end

class CliRawCommandTest < Test::Unit::TestCase
  def setup
    @fake_uart = FakeUart.new
    @fake_uart_class = Class.new do
      def self.open(_port, _baud, &block); block.call(@_fake); end
      class << self; attr_accessor :_fake; end
    end
    @fake_uart_class._fake = @fake_uart
    @stderr = StringIO.new
  end

  def test_raw_sends_byte
    StackchanProtocol::CLI.run(
      ["--port", "/dev/cu.test", "raw", "9"],
      env: {}, uart_class: @fake_uart_class, stderr: @stderr
    )
    assert_equal ["9"], @fake_uart.writes
  end

  def test_raw_without_byte_exits_nonzero
    status = StackchanProtocol::CLI.run(
      ["--port", "/dev/cu.test", "raw"],
      env: {}, uart_class: @fake_uart_class, stderr: @stderr
    )
    assert_not_equal 0, status
  end
end

class CliDeviceErrorTest < Test::Unit::TestCase
  def test_device_error_exits_one
    fake_uart = FakeUart.new(read_bytes: "?")
    fake_uart_class = Class.new do
      def self.open(_port, _baud, &block); block.call(@_fake); end
      class << self; attr_accessor :_fake; end
    end
    fake_uart_class._fake = fake_uart
    stderr = StringIO.new

    status = StackchanProtocol::CLI.run(
      ["--port", "/dev/cu.test", "smile"],
      env: {}, uart_class: fake_uart_class, stderr: stderr
    )
    assert_equal 1, status
    assert_match(/device error/i, stderr.string)
  end
end

class CliUnknownFaceTest < Test::Unit::TestCase
  def test_unknown_face_exits_two
    fake_uart = FakeUart.new
    fake_uart_class = Class.new do
      def self.open(_port, _baud, &block); block.call(@_fake); end
      class << self; attr_accessor :_fake; end
    end
    fake_uart_class._fake = fake_uart
    stderr = StringIO.new

    status = StackchanProtocol::CLI.run(
      ["--port", "/dev/cu.test", "rage"],
      env: {}, uart_class: fake_uart_class, stderr: stderr
    )
    assert_equal 2, status
    assert_match(/unknown face/i, stderr.string)
  end
end
