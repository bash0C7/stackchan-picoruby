# Stand-ins for the pc suite, loaded first on BOTH the CRuby orchestrator and
# the host picoruby VM (which has no picoruby-ble gem).
#
# BLE mirrors only what pc/stackchan-pico/app/ble_client.rb's StackchanRadio
# touches. The darwin port's `_event_popped` copies ONE packet out of the Swift
# FIFO into @event_queue; @pending plays the FIFO's role here, so a test can
# check that pop_and_dispatch drains even when nothing is in the queue yet.
class FakeQueue
  def initialize
    @items = []
  end

  def push(v)
    @items << v
  end

  # Only the timeout_ms: 0 shape is exercised here: nil when empty.
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

  module Utils
    def self.little_endian_to_int16(str)
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

  # Test helper: a packet the Swift side has enqueued but Ruby has not drained.
  def push_pending(packet)
    @pending << packet
  end

  # Base decoder is a no-op here; StackchanRadio#packet_callback calls super.
  def packet_callback(event_packet)
  end

  def connect(adv_report)
    @connect_calls << adv_report
  end

  def write_value_of_characteristic_without_response(conn_handle, handle, value)
    @writes << [:write, conn_handle, handle, value]
  end

  def write_characteristic_descriptor_using_descriptor_handle(conn_handle, handle, value)
    @writes << [:descriptor, conn_handle, handle, value]
  end

  private

  def _event_popped
    @event_popped_count += 1
    pkt = @pending.shift
    @event_queue.push(pkt) if pkt
  end
end

# Stand-in for the daemon proxy the CLI gets back from DRb.
class FakeDaemonProxy
  def status
    { ble_connected: true }
  end
end

# Fake clock for the pc suite: sleep_ms advances Machine.board_millis and is recorded.
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
