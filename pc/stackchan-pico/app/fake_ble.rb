# In-memory fake BLE client. Lets the daemon/CLI be verified on the host VM
# without a real StackChan (live BLE = sub-project #5, needs the device).
# Records every frame the daemon writes and mirrors the device dispatcher's
# ACK / detail-frame behaviour closely enough for logic tests.
class FakeBleClient
  attr_accessor :on_unsolicited
  attr_reader :last_detail_frame, :sent_frames

  def initialize
    @sent_frames       = []
    @last_detail_frame = nil
    @on_unsolicited    = nil
    @connected         = false
  end

  def connect
    @connected = true
    self
  end

  def disconnect
    @connected = false
    self
  end

  def connected?
    @connected
  end

  def send
    raise Stackchan::BLE::ConnectionError, "not connected" unless @connected
    b = Stackchan::BLE::SendBuilder.new
    yield b
    b.to_frames.each { |f| write_frame(f) }
    self
  end

  def raw_send(frame)
    raise Stackchan::BLE::ConnectionError, "not connected" unless @connected
    write_frame(frame)
    self
  end

  def write_without_ack(payload)
    raise Stackchan::BLE::ConnectionError, "not connected" unless @connected
    @sent_frames << payload
    $stderr.write("[fake_ble] write_without_ack #{payload.inspect}\n"); $stderr.flush
    self
  end

  # Test helper: simulate a device-initiated head touch.
  def inject_touch(zone)
    cb = @on_unsolicited
    cb.call("<touch:#{zone}>\n") if cb
  end

  private

  def write_frame(frame)
    @sent_frames << frame
    $stderr.write("[fake_ble] write_frame #{frame.inspect}\n"); $stderr.flush
    # Device emits a detail frame after servo / read frames; mirror that so
    # Display#servo returns something non-nil. String includes, NOT an
    # alternation regex — PicoRuby's regexp engine does not support `|`.
    @last_detail_frame =
      if frame.include?("YL:") || frame.include?("YR:") || frame.include?("PU:") || frame.start_with?("<read:")
        "<YL_actual:0,PU_actual:0>\n"
      else
        nil
      end
  end
end
