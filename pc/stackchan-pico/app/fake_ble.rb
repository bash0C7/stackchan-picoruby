# In-memory BLE client for host runs; mirrors the device's ACK / detail behaviour.
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

  def max_write_chunk
    180
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

  def await_audio_done(n)
    self
  end

  private

  def write_frame(frame)
    @sent_frames << frame
    $stderr.write("[fake_ble] write_frame #{frame.inspect}\n"); $stderr.flush
    # String includes, not alternation regex (unsupported on PicoRuby).
    @last_detail_frame =
      if frame.start_with?("<read:")
        "<yaw_raw:0,pitch_raw:0>\n"   # calibration raw read
      elsif frame.include?("YL:") || frame.include?("YR:") || frame.include?("PU:")
        "<YL_actual:0,PU_actual:0>\n" # servo move detail
      else
        nil
      end
  end
end
