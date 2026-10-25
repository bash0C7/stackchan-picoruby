# In-process BLE client that logs frames to stderr instead of talking to a robot.
class FakeBleClient
  # @rbs @last_detail_frame: String?
  # @rbs @on_unsolicited: (^(String frame) -> void)?
  # @rbs @connected: bool

  attr_accessor :on_unsolicited #: (^(String frame) -> void)?
  attr_reader :last_detail_frame #: String?

  # Builds a disconnected client.
  #: () -> void
  def initialize
    @last_detail_frame = nil
    @on_unsolicited    = nil
    @connected         = false
  end

  # Marks the client connected and returns self.
  #: () -> self
  def connect
    @connected = true
    self
  end

  # Marks the client disconnected and returns self.
  #: () -> self
  def disconnect
    @connected = false
    self
  end

  # Returns whether connect has been called since the last disconnect.
  #: () -> bool
  def connected?
    @connected
  end

  # Returns false; the fake link is never lost.
  #: () -> bool
  def lost?
    false
  end

  # Does nothing and returns self.
  #: () -> self
  def drain
    self
  end

  # Marks the client disconnected.
  #: () -> bool
  def reset_link
    @connected = false
  end

  # Logs the call and returns an empty touch list. Raises ConnectionError when not connected.
  #: () -> Array[Integer]
  def keepalive
    raise StackChan::Controller::ConnectionError, "not connected" unless @connected
    $stderr.write("[fake_ble] remote touches []\n"); $stderr.flush
    []
  end

  # Yields a SendBuilder and logs each frame it builds. Raises ConnectionError when not connected.
  #: () { (StackChan::Controller::SendBuilder) -> void } -> self
  def send
    raise StackChan::Controller::ConnectionError, "not connected" unless @connected
    b = StackChan::Controller::SendBuilder.new
    yield b
    b.to_frames.each { |f| write_frame(f) }
    self
  end

  # Logs one frame. Raises ConnectionError when not connected.
  #: (String frame) -> self
  def raw_send(frame)
    raise StackChan::Controller::ConnectionError, "not connected" unless @connected
    write_frame(frame)
    self
  end

  # Logs a remote call and returns a fake reply line. Raises ConnectionError when not connected.
  #: (Symbol msg, Array[untyped] args) -> Array[String]
  def call_front(msg, args)
    raise StackChan::Controller::ConnectionError, "not connected" unless @connected
    $stderr.write("[fake_ble] remote #{msg} #{args.inspect}\n"); $stderr.flush
    ["<#{msg}:fake>\n"]
  end

  private

  # Logs frame and records the detail line a robot would reply with, or nil.
  #: (String frame) -> String?
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
