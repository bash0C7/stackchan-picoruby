require_relative "test_helper"
require "stackchan/ble"

# Fake transport that imitates corebluetooth_mac's surface enough for Client tests.
class FakeTransport
  attr_reader :writes, :raw_writes, :state, :closed, :scan_calls, :connect_calls
  attr_accessor :scan_result, :ack_replies

  def initialize
    @state         = :idle
    @writes        = []
    @raw_writes    = []
    @scan_calls    = []
    @connect_calls = []
    @ack_replies   = [".", ".", ".", "."]  # default: 4 OKs for max-4-frame send
    @closed        = false
    @rx_char = FakeChar.new(:rx, self)
    @tx_char = FakeChar.new(:tx, self)
  end

  # Called by Client when it does a Write With Response (response: true) on RX.
  # Records the payload + response flag; no ACK is delivered (audio carries none).
  def record_raw_write(payload, response)
    @raw_writes << [payload, response]
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
  def max_write_length(response: true)
    response ? 509 : 182
  end
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

  def write(payload, response: true)
    @transport.record_raw_write(payload, response)
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
    @q = Thread::Queue.new
  end

  def push(value)
    @q.push(value)
  end

  # Blocks up to `timeout` seconds; returns nil on timeout (mirrors the real
  # corebluetooth subscription). Ruby 3.2+ Queue#pop(timeout:).
  def next_value(timeout:)
    @q.pop(timeout: timeout)
  rescue ThreadError
    nil
  end

  def script_returns(*values)
    values.each { |v| @q.push(v) }
  end

  def remaining_count
    @q.size
  end
end

# Minimal scripted-transport fakes for servo detail-drain tests.
class ScriptedFakeRxChar
  attr_reader :writes
  def initialize(subscription)
    @subscription = subscription
    @writes = []
  end

  def write_without_response(payload)
    @writes << payload
    # Delivery is pre-scripted in the subscription; no push needed here.
  end
end

class ScriptedFakeTxChar
  def initialize(subscription)
    @subscription = subscription
  end

  def subscribe
    @subscription
  end

  def unsubscribe; end
end

class ScriptedFakePeripheral
  def initialize(rx_char:, tx_char:)
    @rx_char = rx_char
    @tx_char = tx_char
  end

  def discover_services(timeout:); end
  def services; []; end
  def find_characteristic(uuid)
    case uuid.downcase
    when "6e400002-b5a3-f393-e0a9-e50e24dcca9e" then @rx_char
    when "6e400003-b5a3-f393-e0a9-e50e24dcca9e" then @tx_char
    else nil
    end
  end
end

class ScriptedFakeTransport
  def initialize(peripheral:)
    @peripheral = peripheral
  end

  def scan(name: nil, timeout: nil)
    [FakeDevice.new(name || "Foo")]
  end

  def connect(_device, timeout:)
    @peripheral
  end

  def disconnect(_peripheral); end
  def close; end
end

class ClientConnectTest < Test::Unit::TestCase
  def setup
    @transport = FakeTransport.new
    @client = Stackchan::BLE::Client.new(
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
    @client = Stackchan::BLE::Client.new(
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
    assert_raise(Stackchan::BLE::DeviceError) do
      @client.send do |s|
        s.face(:joy)
      end
    end
  end

  def test_send_propagates_partial_failure_after_first_ok
    @transport.ack_replies = [".", "?"]
    assert_raise(Stackchan::BLE::DeviceError) do
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

class ClientServoDetailDrainTest < Test::Unit::TestCase
  def make_client(subscription)
    rx_char  = ScriptedFakeRxChar.new(subscription)
    tx_char  = ScriptedFakeTxChar.new(subscription)
    periph   = ScriptedFakePeripheral.new(rx_char: rx_char, tx_char: tx_char)
    transport = ScriptedFakeTransport.new(peripheral: periph)
    Stackchan::BLE::Client.new(device_name: "Foo", transport: transport)
  end

  def test_servo_frame_drains_trailing_detail_frame_from_subscription
    subscription = FakeSubscription.new
    subscription.script_returns(".\n", "<YL_actual:0,PU_actual:50>\n")
    client = make_client(subscription)
    client.connect

    client.send do |s|
      s.head(yaw_left: 0, pitch_up: 600, time_ms: 250)
    end

    assert_equal 0, subscription.remaining_count,
                 "servo frame's trailing detail frame must be drained from subscription queue"
  end

  # Regression: <YL:0> (axis-only, no T/V modifier) must also be recognized
  # as a servo frame. The old [YPVT]: regex matched single-char keys only
  # and silently skipped detail-drain for YL/YR/PU without trailing T/V.
  def test_axis_only_servo_frame_without_time_or_velocity_drains_detail
    subscription = FakeSubscription.new
    subscription.script_returns(".\n", "<YR_actual:2,PU_actual:33>\n")
    client = make_client(subscription)
    client.connect

    client.send do |s|
      s.head(yaw_left: 0)
    end

    assert_equal 0, subscription.remaining_count,
                 "<YL:0> alone (no T/V) must also drain the trailing detail frame"
    assert_equal "<YR_actual:2,PU_actual:33>\n", client.last_detail_frame
  end

  def test_non_servo_frame_does_not_attempt_extra_read
    subscription = FakeSubscription.new
    subscription.script_returns(".\n")  # only ONE notification scripted
    client = make_client(subscription)
    client.connect

    # No exception — face frame consumes exactly 1 ACK, no detail read attempted.
    assert_nothing_raised do
      client.send { |s| s.face(:joy) }
    end

    assert_equal 0, subscription.remaining_count,
                 "face frame must not attempt to read a detail frame"
  end

  def test_read_pos_frame_drains_trailing_detail_frame_from_subscription
    subscription = FakeSubscription.new
    subscription.script_returns(".\n", "<yaw_raw:485,pitch_raw:628>\n")
    client = make_client(subscription)
    client.connect

    client.send do |s|
      s.read_pos
    end

    assert_equal "<yaw_raw:485,pitch_raw:628>\n", client.last_detail_frame
  end

  def test_read_pos_unknown_detail_frame_still_drained
    subscription = FakeSubscription.new
    subscription.script_returns(".\n", "<yaw_raw:unknown,pitch_raw:unknown>\n")
    client = make_client(subscription)
    client.connect

    client.send do |s|
      s.read_pos
    end

    assert_equal "<yaw_raw:unknown,pitch_raw:unknown>\n", client.last_detail_frame
  end
end

class ClientDemuxTest < Test::Unit::TestCase
  def make_client(subscription)
    rx_char   = ScriptedFakeRxChar.new(subscription)
    tx_char   = ScriptedFakeTxChar.new(subscription)
    periph    = ScriptedFakePeripheral.new(rx_char: rx_char, tx_char: tx_char)
    transport = ScriptedFakeTransport.new(peripheral: periph)
    Stackchan::BLE::Client.new(device_name: "Foo", transport: transport)
  end

  def test_unsolicited_touch_frame_goes_to_callback_not_ack
    subscription = FakeSubscription.new
    client = make_client(subscription)
    got = []
    client.on_unsolicited = ->(frame) { got << frame }
    client.connect
    subscription.push("<touch:1>\n")
    sleep 0.05
    assert_equal ["<touch:1>\n"], got
  ensure
    client&.disconnect
  end

  def test_ack_still_resolves_send_with_touch_interleaved
    subscription = FakeSubscription.new
    client = make_client(subscription)
    got = []
    client.on_unsolicited = ->(frame) { got << frame }
    client.connect
    subscription.push("<touch:2>\n")
    subscription.push(".\n")
    assert_nothing_raised { client.raw_send("<F:1>\n") }
    sleep 0.05
    assert_equal ["<touch:2>\n"], got
  ensure
    client&.disconnect
  end

  def test_disconnect_stops_reader_thread
    subscription = FakeSubscription.new
    client = make_client(subscription)
    client.connect
    client.disconnect
    assert_true true
  end
end

class ClientRawWriteTest < Test::Unit::TestCase
  def setup
    @transport = FakeTransport.new
    @client = Stackchan::BLE::Client.new(
      device_name: "StackChan-PicoRuby",
      transport:   @transport,
    )
    @client.connect
  end

  def test_write_without_ack_default_uses_write_without_response
    @client.write_without_ack("hello")
    assert_equal ["hello"], @transport.writes
    assert_equal [], @transport.raw_writes
  end

  def test_write_without_ack_response_true_uses_write_with_response
    @client.write_without_ack("audio", response: true)
    assert_equal [["audio", true]], @transport.raw_writes
    assert_equal [], @transport.writes
  end

  def test_max_write_chunk_response_true_returns_with_response_cap
    assert_equal 509, @client.max_write_chunk(response: true)
  end

  def test_max_write_chunk_default_returns_without_response_cap
    assert_equal 182, @client.max_write_chunk(response: false)
  end
end
