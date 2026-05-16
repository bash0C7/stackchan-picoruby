require "test_helper"

# Fake transport that imitates corebluetooth_mac's surface enough for Client tests.
class FakeTransport
  attr_reader :writes, :state, :closed, :scan_calls, :connect_calls
  attr_accessor :scan_result, :ack_replies

  def initialize
    @state         = :idle
    @writes        = []
    @scan_calls    = []
    @connect_calls = []
    @ack_replies   = [".", ".", ".", "."]  # default: 4 OKs for max-4-frame send
    @closed        = false
    @rx_char = FakeChar.new(:rx, self)
    @tx_char = FakeChar.new(:tx, self)
  end

  def scan(name:, timeout:)
    @scan_calls << [name, timeout]
    [FakeDevice.new(@scan_result || name)]
  end

  def connect(_device, timeout:)
    @connect_calls << timeout
    @state = :connected
    FakePeripheral.new(@rx_char, @tx_char)
  end

  def disconnect(_peripheral)
    @state = :disconnected
  end

  def close
    @closed = true
  end

  # Called by Client when it write_without_response on RX. Consumes one ack reply.
  def record_write(payload)
    @writes << payload
    @tx_char.deliver(@ack_replies.shift || ".")
  end
end

class FakeDevice
  attr_reader :name, :identifier, :rssi
  def initialize(name)
    @name = name
    @identifier = "FAKE-#{name}"
    @rssi = -50
  end
end

class FakePeripheral
  def initialize(rx, tx)
    @rx = rx
    @tx = tx
  end

  def discover_services(timeout:); end
  def services; []; end
  def find_characteristic(uuid)
    case uuid.downcase
    when "6e400002-b5a3-f393-e0a9-e50e24dcca9e" then @rx
    when "6e400003-b5a3-f393-e0a9-e50e24dcca9e" then @tx
    else nil
    end
  end
end

class FakeChar
  def initialize(kind, transport)
    @kind = kind
    @transport = transport
    @subscription = nil
  end

  def write_without_response(payload)
    @transport.record_write(payload)
  end

  def subscribe
    @subscription = FakeSubscription.new
  end

  def unsubscribe
    @subscription = nil
  end

  def deliver(value)
    @subscription&.push(value)
  end
end

class FakeSubscription
  def initialize
    @queue = []
  end

  def push(value)
    @queue << value
  end

  def next_value(timeout:)
    @queue.shift  # ignore timeout — fake delivers synchronously
  end
end

class ClientConnectTest < Test::Unit::TestCase
  def setup
    @transport = FakeTransport.new
    @client = StackchanBleClient::Client.new(
      device_name: "StackChan-PicoRuby",
      transport:   @transport,
    )
  end

  def test_connect_scans_for_device_name
    @client.connect
    assert_equal [["StackChan-PicoRuby", 10.0]], @transport.scan_calls
  end

  def test_connect_records_connect_call
    @client.connect
    assert_equal 1, @transport.connect_calls.size
  end

  def test_disconnect_closes_transport
    @client.connect
    @client.disconnect
    assert_equal :disconnected, @transport.state
    assert_true @transport.closed
  end
end

class ClientSendTest < Test::Unit::TestCase
  def setup
    @transport = FakeTransport.new
    @client = StackchanBleClient::Client.new(
      device_name: "StackChan-PicoRuby",
      transport:   @transport,
    )
    @client.connect
  end

  def test_send_face_only_sends_one_frame
    @client.send do |s|
      s.face(:joy)
    end
    assert_equal ["<F:2>\n"], @transport.writes
  end

  def test_send_led_both_named_one_frame
    @client.send do |s|
      s.led(:red, mode: :blink)
    end
    assert_equal ["<L:1,R:255,G:0,B:0,S:B,M:b>\n"], @transport.writes
  end

  def test_send_combo_face_and_led_sends_two_frames_in_order
    @client.send do |s|
      s.face(:joy)
      s.led(:red, mode: :blink)
    end
    assert_equal [
      "<F:2>\n",
      "<L:1,R:255,G:0,B:0,S:B,M:b>\n",
    ], @transport.writes
  end

  def test_send_raises_device_error_when_ack_is_question_mark
    @transport.ack_replies = ["?"]
    assert_raise(StackchanBleClient::DeviceError) do
      @client.send do |s|
        s.face(:joy)
      end
    end
  end

  def test_send_propagates_partial_failure_after_first_ok
    @transport.ack_replies = [".", "?"]
    assert_raise(StackchanBleClient::DeviceError) do
      @client.send do |s|
        s.face(:joy)
        s.led(:red)
      end
    end
    # both writes were attempted
    assert_equal 2, @transport.writes.size
  end

  def test_send_4_frames_in_left_right_combo
    @client.send do |s|
      s.face(:joy)
      s.led(:red,  side: :both)
      s.led(:blue, side: :left)
      s.led(:green, side: :right, mode: :breathing)
    end
    assert_equal 4, @transport.writes.size
  end
end
