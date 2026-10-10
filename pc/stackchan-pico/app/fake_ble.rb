class FakeBleClient
  attr_accessor :on_unsolicited
  attr_reader :last_detail_frame

  def initialize
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

  def lost?
    false
  end

  def drain
    self
  end

  def reset_link
    @connected = false
  end

  def keepalive
    raise StackChan::Controller::ConnectionError, "not connected" unless @connected
    write_frame("<read:pos>\n")
    self
  end

  def send
    raise StackChan::Controller::ConnectionError, "not connected" unless @connected
    b = StackChan::Controller::SendBuilder.new
    yield b
    b.to_frames.each { |f| write_frame(f) }
    self
  end

  def raw_send(frame)
    raise StackChan::Controller::ConnectionError, "not connected" unless @connected
    write_frame(frame)
    self
  end

  def write_without_ack(payload)
    raise StackChan::Controller::ConnectionError, "not connected" unless @connected
    $stderr.write("[fake_ble] write_without_ack #{payload.inspect}\n"); $stderr.flush
    self
  end

  def await_audio_done(n)
    self
  end

  def call_front(msg, args)
    raise StackChan::Controller::ConnectionError, "not connected" unless @connected
    $stderr.write("[fake_ble] remote #{msg} #{args.inspect}\n"); $stderr.flush
    ["<#{msg}:fake>\n"]
  end

  private

  def write_frame(frame)
    $stderr.write("[fake_ble] write_frame #{frame.inspect}\n"); $stderr.flush
    @last_detail_frame =
      if frame.start_with?("<read:")
        "<yaw_raw:0,pitch_raw:0>\n"
      elsif frame.include?("YL:") || frame.include?("YR:") || frame.include?("PU:")
        "<YL_actual:0,PU_actual:0>\n"
      else
        nil
      end
  end
end
