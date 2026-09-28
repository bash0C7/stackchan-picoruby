module StackChan
  def self.robot
    raise ArgumentError, "StackChan.robot needs a block" unless block_given?
    robot = Robot.new
    yield Robot::Builder.new(robot)
    robot.validate
    robot
  end

  class Robot
    class Wiring
      attr_reader :dispatcher, :ticker, :remote, :handle

      def initialize(dispatcher, ticker, remote)
        @dispatcher = dispatcher
        @ticker     = ticker
        @remote     = remote
        @handle     = dispatcher.robot_handle
      end
    end

    attr_reader :faces, :face_index, :boot_handlers, :touch_handlers,
                :frame_handlers, :remote_handlers, :periodic
    attr_accessor :release_after

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

    def wire(display:, led:, head: nil, touch: nil, speaker: nil, stdout:, notify:)
      dispatcher = Dispatcher.new(
        display: display, led: led, stdout: stdout, head: head, speaker: speaker,
        faces: @faces, face_index: @face_index, frame_handlers: @frame_handlers
      )
      ticker = Ticker.new(
        display: display, led: led, touch: touch, dispatcher: dispatcher, notify: notify,
        touch_handlers: @touch_handlers, periodic: @periodic
      )
      Wiring.new(dispatcher, ticker, Remote.new(dispatcher, remote_handlers: @remote_handlers))
    end

    def run
      serve(Boot, Peripheral)
    end

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

    def run_on_boot(handle)
      i = 0
      while i < @boot_handlers.size
        @boot_handlers[i].call(handle)
        i += 1
      end
    end
  end
end
