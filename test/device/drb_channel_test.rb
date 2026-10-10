class DrbChannelTest < Picotest::Test
  DRX = 0x21; DTX = 0x24; DCCCD = 0x25

  class FakeServo
    attr_reader :writes
    attr_accessor :next_read, :last_read_error, :last_status
    def initialize; @writes = []; @next_read = 0; end
    def write_pos(pos, time_ms:, speed:); @writes << [pos, time_ms, speed]; end
    def read_pos; @next_read; end
    def enable_torque(_on); end
  end

  class Port
    attr_reader :notifies
    def initialize; @writes = {}; @notifies = []; end
    def queue_write(h, v); (@writes[h] ||= []) << v; end
    def pop_event(timeout_ms:); nil; end
    def event_popped; end
    def take_write(h); l = @writes[h]; l && l.shift; end
    def send_notification(h, f); @notifies << [h, f]; end
  end

  class NullTicker
    def tick(_now); end
  end

  class CentralLink
    def initialize(port, loop_)
      @port = port
      @loop = loop_
      @seen = 0
    end

    def send_chunk(bytes)
      @port.queue_write(DRX, bytes)
    end

    def poll
      @loop.tick
      while @seen < @port.notifies.length
        h, v = @port.notifies[@seen]
        @seen += 1
        return v if h == DTX
      end
      nil
    end
  end

  def setup
    @yaw = FakeServo.new
    @pitch = FakeServo.new
    @display = FakeDisplay.new
    @head = StackChan::Robot::Head.new(@yaw, @pitch)
    @dispatcher = RobotTables.dispatcher(
      display: @display, led: (@led = FakeLed.new), stdout: nil,
      head: @head
    )
    @port = Port.new
    @front = StackChan::Robot::Remote.new(@dispatcher, remote_handlers: {
      wave: ->(r, level) { r.head(yaw_left: level, time: 300) },
    }, head: @head)
    @channel = StackChan::Robot::DrbChannel.new(
      rx_handle: DRX, tx_handle: DTX, cccd_handle: DCCCD,
      responder: DRbBle::Responder.new(@front, allow: @front.exposed)
    )
    @loop = StackChan::Robot::LinkLoop.new(
      port: @port, ticker: NullTicker.new, on_packet: ->(_p) {},
      clock: -> { 0 }, drb: @channel, remote: @front
    )
    DRbBle.register("drbble://stackchan", CentralLink.new(@port, @loop), timeout_ms: 200)
    @remote = DRb::DRbObject.new_with_uri("drbble://stackchan")
  end

  def subscribe
    @port.queue_write(DCCCD, "\x01\x00")
    @loop.tick
  end

  def test_servo_call_moves_head_and_returns_the_text_link_lines
    subscribe
    @yaw.next_read = 332
    @pitch.next_read = 781
    lines = @remote.servo({ YL: 50, PU: 50, T: 2000 })
    assert_equal [[332, 2000, 0]], @yaw.writes
    assert_equal [[781, 2000, 0]], @pitch.writes
    assert_equal [".\n", "<YL_actual:50,PU_actual:50>\n"], lines
  end

  def test_bad_face_id_answers_the_error_line
    subscribe
    assert_equal ["?\n"], @remote.face(9)
  end

  def test_nothing_is_notified_before_subscribe
    req = DRbBle::Writer.new
    DRb::DRbMessage.new(req).send_request(nil, :read_pos, [], nil)
    @port.queue_write(DRX, req.out)
    @loop.tick
    assert_equal [], @port.notifies
  end

  def test_service_reports_whether_the_central_wrote_to_the_drb_pair
    assert_equal false, @channel.service(@port)
    @port.queue_write(DCCCD, "\x01\x00")
    assert_equal true, @channel.service(@port)
    @port.queue_write(DRX, "\x00\x00")
    assert_equal true, @channel.service(@port)
    assert_equal false, @channel.service(@port)
  end

  def test_disconnect_drops_a_partial_request
    subscribe
    @port.queue_write(DRX, "\x00\x00")
    @loop.tick
    @loop.disconnected
    subscribe
    assert_equal ["?\n"], @remote.face(9)
  end

  def test_replies_wait_for_a_new_subscribe_after_a_disconnect
    subscribe
    @loop.disconnected
    req = DRbBle::Writer.new
    DRb::DRbMessage.new(req).send_request(nil, :read_pos, [], nil)
    @port.queue_write(DRX, req.out)
    @loop.tick
    assert_equal [], @port.notifies.select { |n| n[0] == DTX }
  end

  def test_servo_and_led_are_command
    subscribe
    assert_equal [".\n"], @remote.led({ L: 1, M: "s", S: "B", R: 10, G: 20, B: 30 })
    assert_equal [[:animate_side, [:both, 10, 20, 30, :solid]]], @led.calls
  end

  def test_exposed_is_the_built_ins_then_the_remote_handler_names
    assert_equal [:command, :servo, :led, :face, :text, :torque, :read_pos, :stack_free,
                  :selftest, :touches, :audio_begin, :audio_chunk, :audio_play, :audio_done,
                  :servo_health, :wave], @front.exposed
  end

  def test_a_remote_handler_receives_the_handle_and_the_arguments_and_moves_the_head
    subscribe
    assert_equal true, @remote.wave(50)
    assert_equal [[332, 300, 0]], @yaw.writes
  end

  def test_a_name_that_is_neither_built_in_nor_a_handler_is_not_exposed
    subscribe
    err = nil
    begin
      @remote.shake
    rescue => e
      err = e
    end
    assert_equal "NoMethodError: shake is not exposed", err.message
  end

  def test_a_handler_name_called_on_the_front_without_a_handler_table_raises_no_method_error
    front = StackChan::Robot::Remote.new(@dispatcher)
    assert_raise(NoMethodError) { front.wave(50) }
  end

  def test_stack_free_is_unknown_when_the_machine_has_no_high_water_mark
    subscribe
    assert_equal ["<stack_free:unknown>\n"], @remote.stack_free
  end

  def test_stack_free_returns_the_same_lines_type_as_the_other_built_ins
    assert_equal StackChan::Robot::Remote::Lines, @front.stack_free.class
  end

  def test_servo_health_reports_each_axis_error_and_status
    @yaw.last_read_error = :no_header
    @yaw.last_status = nil
    @pitch.last_read_error = nil
    @pitch.last_status = 0
    subscribe
    assert_equal ["<yaw_err:no_header,yaw_status:unknown,pitch_err:none,pitch_status:0>\n"], @remote.servo_health
  end

  def test_servo_health_without_a_head_answers_question_mark
    front = StackChan::Robot::Remote.new(@dispatcher, head: nil)
    assert_equal ["?\n"], front.servo_health
  end
end
