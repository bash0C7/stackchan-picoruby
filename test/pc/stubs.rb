class FakeQueue
  def initialize
    @items = []
  end

  def push(v)
    @items << v
  end

  def pop(timeout_ms: nil)
    @items.shift
  end

  def size
    @items.size
  end
end

class BLE
  HCI_CON_HANDLE_INVALID  = 0xffff
  GATT_EVENT_NOTIFICATION = 0xA7
  HCI_EVENT_LE_META = 0x3E
  HCI_EVENT_DISCONNECTION_COMPLETE = 0x05

  module Utils
    def self.little_endian_to_int16(str)
      return 0 unless str
      (str.getbyte(0) || 0) | ((str.getbyte(1) || 0) << 8)
    end
  end

  attr_reader :role, :services, :state, :event_popped_count, :connect_calls, :writes

  def initialize(role, profile_data = nil)
    @role = role
    @event_queue = FakeQueue.new
    @pending = []
    @event_popped_count = 0
    @conn_handle = HCI_CON_HANDLE_INVALID
    @services = []
    @state = :TC_OFF
    @connect_calls = []
    @writes = []
  end

  def push_pending(packet)
    @pending << packet
  end

  def scan(timeout_ms: nil, stop_state: :TC_IDLE)
  end

  def packet_callback(event_packet)
  end

  def connect(adv_report)
    @connect_calls << adv_report
    true
  end

  def write_value_of_characteristic_without_response(conn_handle, handle, value)
    @writes << [:write, conn_handle, handle, value]
    0
  end

  def write_characteristic_descriptor_using_descriptor_handle(conn_handle, handle, value)
    @writes << [:descriptor, conn_handle, handle, value]
    0
  end

  private

  def _event_popped
    @event_popped_count += 1
    pkt = @pending.shift
    @event_queue.push(pkt) if pkt
  end
end

class FakeDaemonProxy
  def status
    { ble_connected: true }
  end
end

module FakeClock
  @now = 0
  @sleeps = []
  def self.now = @now
  def self.sleeps = @sleeps
  def self.reset(now)
    @now = now
    @sleeps = []
  end
  def self.sleep(ms)
    @sleeps << ms
    @now += ms
  end
end

module Machine
  def self.board_millis = FakeClock.now
end

def sleep_ms(ms)
  FakeClock.sleep(ms)
end

module DRb
  @stop_service_calls = 0
  def self.stop_service_calls = @stop_service_calls
  def self.reset_stop_service_calls
    @stop_service_calls = 0
  end

  def self.stop_service
    @stop_service_calls += 1
  end

  def self.create_socket(uri)
    nil
  end
end

unless Object.const_defined?(:Task)
  class Task
    attr_reader :name

    def initialize(name: nil, &block)
      @name = name
      @block = block
    end

    def terminate
    end
  end
end

class FakeStoppableBle
  attr_accessor :on_unsolicited
  attr_reader :disconnect_calls

  def initialize
    @disconnect_calls = 0
  end

  def disconnect
    @disconnect_calls += 1
  end
end
