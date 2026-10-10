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
    @packets.each { |packet| packet_callback(packet) }
    @packets.clear
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
    raise TypeError, "handle is nil" if handle.nil?
    if @dropped
      @writes_after_drop << [handle, value]
      return false
    end
    @writes << [handle, value]
    true
  end

  def write_characteristic_descriptor_using_descriptor_handle(_conn_handle, handle, value)
    raise TypeError, "handle is nil" if handle.nil?
    @descriptor_writes << [handle, value]
  end
end

class FakeRobotServo
  def initialize(zero)
    @pos = zero
  end

  def write_pos(pos, time_ms:, speed:)
    @pos = pos
  end

  def read_pos
    @pos
  end

  def enable_torque(_on)
  end

  def last_read_error
    nil
  end

  def last_status
    nil
  end
end

class FakeRobotSpeaker
  class I2sSink
    def write(_bytes)
    end
  end

  attr_reader :played

  def initialize
    @played = []
    @i2s = I2sSink.new
  end

  def i2s
    @i2s
  end

  def play_ulaw(bytes)
    @played << bytes
  end
end

class NullSink
  def write(_s)
  end
end

class LoggingRemote < StackChan::Robot::Remote
  def initialize(dispatcher, remote_handlers: {}, speaker: nil, head: nil, log:)
    super(dispatcher, remote_handlers: remote_handlers, speaker: speaker, head: head)
    @log = log
  end

  def command(frame)
    @log << Stackchan::BLE::FrameCodec.encode_pairs(frame)
    super
  end
end

class FakeRobotRadio < FakeRadio
  DRX   = 0x21
  DTX   = 0x24
  DCCCD = 0x26

  def self.nus_services
    nus = StackChan::Controller::Nus
    [{ characteristics: [
      { uuid128: nus.drb_rx_uuid, value_handle: DRX, descriptors: [] },
      { uuid128: nus.drb_tx_uuid, value_handle: DTX, descriptors: [{ uuid128: nus.cccd_uuid, handle: DCCCD }] },
    ] }]
  end

  attr_reader :rx_frames, :display, :led, :speaker, :remote, :dispatcher, :touches_calls

  def initialize(services: FakeRobotRadio.nus_services, conn_handle: 1, target: :fake_target)
    super(services: services, conn_handle: conn_handle, target: target)
    @rx_frames = []
    @touches_calls = 0
    @release_after_ms = nil
    @last_rx_at = FakeClock.now
    @display = FakeDisplay.new
    @led     = FakeLed.new
    @yaw     = FakeRobotServo.new(StackChan::Robot::Head::SERVO_YAW_ZERO)
    @pitch   = FakeRobotServo.new(StackChan::Robot::Head::SERVO_PITCH_ZERO)
    @head    = StackChan::Robot::Head.new(@yaw, @pitch)
    @speaker = FakeRobotSpeaker.new
    @dispatcher = RobotTables.dispatcher(display: @display, led: @led, stdout: NullSink.new,
                                          head: @head, speaker: @speaker)
    @remote = LoggingRemote.new(@dispatcher, speaker: @speaker, head: @head, log: @rx_frames)
    @responder = DRbBle::Responder.new(@remote, allow: @remote.exposed)
  end

  def release_after(ms)
    @release_after_ms = ms
    @last_rx_at = FakeClock.now
  end

  def touch(zone)
    return if link_dropped?
    @remote.push_touch(zone)
  end

  def before_pop
    return unless @release_after_ms
    return if link_dropped?
    drop_link(event: true) if FakeClock.now - @last_rx_at >= @release_after_ms
  end

  def link_up
    @last_rx_at = FakeClock.now
  end

  def before_drx_write(_value)
    :continue
  end

  def write_value_of_characteristic_without_response(conn_handle, handle, value)
    return false unless super
    @last_rx_at = FakeClock.now
    if handle == DRX
      @touches_calls += 1 if value.include?("touches")
      return true if before_drx_write(value) == :drop
      reply = @responder.feed(value)
      @remote.perform_audio_play
      DRbBle.chunks(reply, 20).each { |chunk| schedule_notification(DTX, chunk) }
      return true
    end
    true
  end
end
