# Entry point of the robot DSL: StackChan.robot builds a validated StackChan::Robot.
module StackChan
  # Evaluates the block against a Robot::Builder, validates the result and returns the Robot.
  # Raises ArgumentError without a block or when validation fails.
  #: () { (Robot::Builder) -> void } -> Robot
  def self.robot
    raise ArgumentError, "StackChan.robot needs a block" unless block_given?
    robot = Robot.new
    yield Robot::Builder.new(robot)
    robot.validate
    robot
  end

  # Robot definition collected by the DSL, and the runner that boots the hardware and serves BLE.
  class Robot
    # @rbs!
    #   interface _Display
    #     def draw_rect: (Integer x, Integer y, Integer w, Integer h, Integer color, ?fill: bool) -> void
    #     def draw_ellipse: (Integer cx, Integer cy, Integer rx, Integer ry, Integer color, ?fill: bool) -> void
    #     def draw_line: (Integer x0, Integer y0, Integer x1, Integer y1, Integer color) -> void
    #     def draw_text: (Integer x, Integer y, String text, font: String, fg: Integer, bg: Integer) -> void
    #   end
    #   interface _Writer
    #     def write: (String data) -> untyped
    #   end
    #   type frame = Hash[String, String]
    #   type boot_handler = ^(Handle) -> void
    #   type touch_handler = ^(Handle) -> void
    #   type periodic_handler = ^(Handle) -> void
    #   type frame_handler = ^(Handle, String) -> bool
    #   type remote_handler = ^(Handle, *untyped) -> untyped

    # Wired runtime objects of one robot: dispatcher, ticker, dRuby front and the handle given to handlers.
    class Wiring
      attr_reader :dispatcher #: Dispatcher
      attr_reader :ticker #: Ticker
      attr_reader :remote #: Remote
      attr_reader :handle #: Handle

      # Stores the three objects and takes the handle from the dispatcher.
      #: (Dispatcher dispatcher, Ticker ticker, Remote remote) -> void
      def initialize(dispatcher, ticker, remote)
        @dispatcher = dispatcher
        @ticker     = ticker
        @remote     = remote
        @handle     = dispatcher.robot_handle
      end
    end

    attr_reader :faces #: Hash[Symbol, Face]
    attr_reader :face_index #: Hash[String, Symbol]
    attr_reader :boot_handlers #: Array[boot_handler]
    attr_reader :touch_handlers #: Hash[Integer, touch_handler]
    attr_reader :frame_handlers #: Hash[String, frame_handler]
    attr_reader :remote_handlers #: Hash[Symbol, remote_handler]
    attr_reader :periodic #: Array[[Integer, periodic_handler]]
    attr_accessor :release_after #: Integer?

    # Creates an empty definition with no faces, handlers or release time.
    #: () -> void
    def initialize
      @faces           = {}
      @face_index      = {}
      @boot_handlers   = []
      @touch_handlers  = {}
      @frame_handlers  = {}
      @remote_handlers = {}
      @periodic        = []
      @release_after   = nil
    end

    # Checks that :neutral and :closed faces exist and every face_index entry names a defined face.
    # Raises ArgumentError otherwise.
    #: () -> void
    def validate
      raise ArgumentError, "StackChan.robot: face :neutral is not defined" unless @faces[:neutral]
      raise ArgumentError, "StackChan.robot: face :closed is not defined" unless @faces[:closed]
      keys = @face_index.keys
      i = 0
      while i < keys.size
        name = @face_index[keys[i]]
        unless @faces[name]
          raise ArgumentError, "StackChan.robot: face_index #{keys[i].inspect} names undefined face #{name.inspect}"
        end
        i += 1
      end
    end

    # Builds the Dispatcher, Remote and Ticker for the given devices and returns them as a Wiring.
    #: (display: _Display, led: StackchanLed, ?head: Head?, ?touch: Si12T?, ?speaker: AW88298?, ?stdout: _Writer) -> Wiring
    def wire(display:, led:, head: nil, touch: nil, speaker: nil, stdout: $stdout)
      dispatcher = Dispatcher.new(
        display: display, led: led, stdout: stdout, head: head, speaker: speaker,
        faces: @faces, face_index: @face_index, frame_handlers: @frame_handlers
      )
      remote = Remote.new(dispatcher, remote_handlers: @remote_handlers, speaker: speaker, head: head)
      ticker = Ticker.new(
        display: display, led: led, touch: touch, dispatcher: dispatcher, remote: remote,
        touch_handlers: @touch_handlers, periodic: @periodic
      )
      Wiring.new(dispatcher, ticker, remote)
    end

    # Boots the hardware and serves the BLE peripheral. Does not return.
    #: () -> void
    def run
      serve(Boot, Peripheral)
    end

    # Waits, runs boot.run, waits again, creates the peripheral, runs the on_boot handlers and runs the peripheral.
    # Does not return.
    #: (singleton(Boot) boot, singleton(Peripheral) peripheral_class) -> void
    def serve(boot, peripheral_class)
      sleep_ms 5000
      devices = boot.run
      sleep_ms 3000
      puts "[application] BLE peripheral starting (infinite advertise)"
      peripheral = peripheral_class.new(
        self,
        display: devices[:display], led: devices[:led], head: devices[:head],
        touch: devices[:touch], speaker: devices[:speaker]
      )
      run_on_boot(peripheral.robot_handle)
      peripheral.run
    end

    # Calls every on_boot handler in order with the handle.
    #: (Handle handle) -> void
    def run_on_boot(handle)
      i = 0
      while i < @boot_handlers.size
        @boot_handlers[i].call(handle)
        i += 1
      end
    end
  end
end
