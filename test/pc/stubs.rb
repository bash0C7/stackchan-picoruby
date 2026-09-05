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
    # picoruby declares this as (String|nil) -> Integer, and the caller feeds it
    # `byteslice` results, so nil has to mean 0 here too rather than raise.
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

  # Test helper: a packet the Swift side has enqueued but Ruby has not drained.
  def push_pending(packet)
    @pending << packet
  end

  # Base decoder is a no-op here; StackchanRadio#packet_callback calls super.
  def packet_callback(event_packet)
  end

  # The three below return what picoruby's BLE::Central declares — bool, and the
  # btstack success code — not the value of the `<<` that records the call. A
  # fake that answers a different type than the device is how a test stays green
  # over a branch the device would take differently.
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

# picoruby-drb is absent from both the CRuby orchestrator and the host VM.
# Daemon#stop only has to be observed for whether it tore the service down.
# drb_eintr_retry.rb aliases create_socket when DRb exists, so the stub carries
# one for that alias to bind to.
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

# The host VM has a real cooperative Task whose body waits for the current task
# to yield, and picotest does not yield inside a test, so a Task created there
# stays pending. CRuby has no Task at all; this gives it the same observable
# behaviour — created, body not yet run.
unless Object.const_defined?(:Task)
  class Task
    attr_reader :name

    def initialize(name: nil, &block)
      @name = name
      @block = block
    end

    def run
      @block.call
    end

    def terminate
    end
  end
end

# Daemon#stop reaches only #disconnect on the BLE client.
class FakeStoppableBle
  attr_reader :disconnect_calls

  def initialize
    @disconnect_calls = 0
  end

  def disconnect
    @disconnect_calls += 1
  end
end
