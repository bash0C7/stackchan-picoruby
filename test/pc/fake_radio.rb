class FakeRadio < StackChan::Controller::Radio
  DISCONNECT_PACKET = [0x3E, 0x01, 0x05]

  attr_accessor :advertising
  attr_reader :writes, :descriptor_writes, :pop_count, :services, :writes_after_drop

  def initialize(services: [], conn_handle: 1, target: :fake_target)
    super(name_prefix: "StackChan")
    @writes = []
    @writes_after_drop = []
    @descriptor_writes = []
    @scheduled = []
    @packets = []
    @pop_count = 0
    @initial_target = target
    @initial_services = services
    @initial_conn_handle = conn_handle
    @target = target
    @services = services
    @conn_handle = conn_handle
    @connect_and_discover_calls = 0
    @advertising = true
    @failing_connects = 0
    @dropped = false
  end

  def schedule_notification(handle, value, after_polls: 1)
    @scheduled << [@pop_count + after_polls, handle, value]
  end

  def deliver_scheduled_on_next_poll
    @scheduled.each { |s| s[0] = @pop_count + 1 }
  end

  def pop_and_dispatch
    @pop_count += 1
    before_pop
    packet = @packets.shift
    if packet
      packet_callback(packet)
      return packet
    end
    idx = @scheduled.index { |s| s[0] <= @pop_count }
    return nil unless idx
    due = @scheduled.delete_at(idx)
    @on_notification.call(due[1], due[2]) if @on_notification
    :notification
  end

  def before_pop
  end

  def connect_and_discover(_timeout_ms)
    @connect_and_discover_calls += 1
    if @failing_connects > 0 || !@advertising
      @failing_connects -= 1 if @failing_connects > 0
      @target = nil
      @conn_handle = BLE::HCI_CON_HANDLE_INVALID
      @services = []
      return
    end
    @target = @initial_target
    @conn_handle = @initial_conn_handle
    @services = @initial_services
    @dropped = false
    link_up
  end

  def link_up
  end

  def connect_and_discover_calls
    @connect_and_discover_calls
  end

  def fail_next_connects(n)
    @failing_connects = n
  end

  def link_dropped?
    @dropped
  end

  def drop_link(event: true)
    @conn_handle = BLE::HCI_CON_HANDLE_INVALID
    @scheduled.clear
    @dropped = true
    @packets << DISCONNECT_PACKET.pack("C*") if event
  end

  def write_value_of_characteristic_without_response(_conn_handle, handle, value)
    if @dropped
      @writes_after_drop << [handle, value]
      return false
    end
    @writes << [handle, value]
    true
  end

  def write_characteristic_descriptor_using_descriptor_handle(_conn_handle, handle, value)
    @descriptor_writes << [handle, value]
  end
end

class FakeRobotRadio < FakeRadio
  RX    = 0x11
  TX    = 0x14
  CCCD  = 0x16
  DRX   = 0x21
  DTX   = 0x24
  DCCCD = 0x26

  def self.nus_services
    nus = StackChan::Controller::Nus
    [{ characteristics: [
      { uuid128: nus.rx_uuid, value_handle: RX, descriptors: [] },
      { uuid128: nus.tx_uuid, value_handle: TX, descriptors: [{ uuid128: nus.cccd_uuid, handle: CCCD }] },
      { uuid128: nus.drb_rx_uuid, value_handle: DRX, descriptors: [] },
      { uuid128: nus.drb_tx_uuid, value_handle: DTX, descriptors: [{ uuid128: nus.cccd_uuid, handle: DCCCD }] },
    ] }]
  end

  attr_reader :rx_frames

  def initialize(services: FakeRobotRadio.nus_services, conn_handle: 1, target: :fake_target)
    super(services: services, conn_handle: conn_handle, target: target)
    @rx_frames = []
    @audio_left = 0
    @release_after_ms = nil
    @last_rx_at = FakeClock.now
  end

  def release_after(ms)
    @release_after_ms = ms
    @last_rx_at = FakeClock.now
  end

  def touch(zone)
    return if link_dropped?
    schedule_notification(TX, "<touch:#{zone}>\n")
  end

  def before_pop
    return unless @release_after_ms
    return if link_dropped?
    drop_link(event: true) if FakeClock.now - @last_rx_at >= @release_after_ms
  end

  def link_up
    @audio_left = 0
    @last_rx_at = FakeClock.now
  end

  def write_value_of_characteristic_without_response(conn_handle, handle, value)
    return false unless super
    @last_rx_at = FakeClock.now
    return true unless handle == RX
    if @audio_left > 0
      @audio_left -= value.bytesize
      schedule_notification(TX, "<A:done>\n") if @audio_left <= 0
      return true
    end
    @rx_frames << value
    answer(value)
    true
  end

  def answer(frame)
    if frame.start_with?("<read:pos>")
      schedule_notification(TX, "<yaw_raw:2048,pitch_raw:2048>\n")
    elsif frame.start_with?("<A:")
      @audio_left = frame[3, frame.length - 3].to_i
      schedule_notification(TX, "<A:ready>\n")
    else
      schedule_notification(TX, ".\n")
      if frame.start_with?("<Y") || frame.start_with?("<PU") || frame.start_with?("<selftest:run>")
        schedule_notification(TX, "<YL_actual:0,PU_actual:0>\n", after_polls: 3)
      end
    end
  end
end
