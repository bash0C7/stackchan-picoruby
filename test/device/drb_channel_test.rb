# The dRuby characteristic pair end to end on the device side: a DRbObject on
# the central writes chunks to the DRb RX handle, LinkLoop's tick feeds them to
# the Responder over Remote, and the reply leaves as TX notifications.
class DrbChannelTest < Picotest::Test
  RX = 0x11; TX = 0x14; CCCD = 0x15
  DRX = 0x21; DTX = 0x24; DCCCD = 0x25

  class FakeServo
    attr_reader :writes
    attr_accessor :next_read
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

  # The central's side of the link: each chunk is a write the peripheral sees
  # on its next tick; notifications on DTX are what poll returns.
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
    @dispatcher = StackchanApp::Dispatcher.new(
      display: @display, led: FakeLed.new, stdout: nil,
      head: StackchanApp::Head.new(@yaw, @pitch)
    )
    @port = Port.new
    @channel = StackchanApp::DrbChannel.new(
      rx_handle: DRX, tx_handle: DTX, cccd_handle: DCCCD,
      responder: DRbBle::Responder.new(StackchanApp::Remote.new(@dispatcher), allow: StackchanApp::Remote::EXPOSED)
    )
    @loop = StackchanApp::LinkLoop.new(
      port: @port, rx_handle: RX, tx_handle: TX, cccd_handle: CCCD,
      ticker: NullTicker.new, on_packet: ->(_p) {}, on_rx: ->(_d) {},
      clock: -> { 0 }, log: ->(_l) {}, drb: @channel
    )
    DRbBle.register("drbble://stackchan", CentralLink.new(@port, @loop), timeout_ms: 200)
    @remote = DRb::DRbObject.new_with_uri("drbble://stackchan")
  end

  def teardown
    DRbBle.unregister("drbble://stackchan")
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
    req = DRbBle::BufferWriter.new
    DRb::DRbMessage.new(req).send_request(nil, :read_pos, [], nil)
    @port.queue_write(DRX, req.out)
    @loop.tick
    assert_equal [], @port.notifies
  end

  def test_text_link_output_is_untouched_by_a_drb_call
    subscribe
    @remote.face(2)
    assert_equal [], @port.notifies.select { |n| n[0] == TX }
  end

  def test_disconnect_drops_a_partial_request
    subscribe
    @port.queue_write(DRX, "\x00\x00")
    @loop.tick
    @loop.disconnected
    assert_false @channel.notify_enabled?
    subscribe
    assert_equal ["?\n"], @remote.face(9)
  end
end
