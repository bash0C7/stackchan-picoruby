module StackChan
  class Robot
    class Remote
      BUILT_INS = [:command, :servo, :led, :face, :text, :torque, :read_pos, :stack_free]

      class Lines < Array
        def write(s)
          push(s)
        end
      end

      attr_reader :exposed

      def initialize(dispatcher, remote_handlers: {})
        @dispatcher = dispatcher
        @handlers   = remote_handlers
        @exposed    = BUILT_INS + remote_handlers.keys
      end

      def command(frame)
        pairs = {}
        keys = frame.keys
        i = 0
        while i < keys.size
          pairs[keys[i].to_s] = frame[keys[i]].to_s
          i += 1
        end
        lines = Lines.new
        @dispatcher.handle_to(pairs, lines)
        lines
      end
      alias servo command
      alias led command

      def face(id)
        command({ "F" => id })
      end

      def text(s)
        command({ "text" => s })
      end

      def torque(on)
        command({ "torque" => (on == true || on.to_s == "on") ? "on" : "off" })
      end

      def read_pos
        command({ "read" => "pos" })
      end

      def stack_free
        free = Machine.respond_to?(:stack_high_water_mark) ? Machine.stack_high_water_mark : "unknown"
        lines = Lines.new
        lines.write("<stack_free:#{free}>\n")
        lines
      end

      def method_missing(name, *args)
        handler = @handlers[name]
        raise NoMethodError, "undefined method '#{name}' for StackChan::Robot::Remote" unless handler
        handler.call(@dispatcher.robot_handle, *args)
      end
    end
  end
end
