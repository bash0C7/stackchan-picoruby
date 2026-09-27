module StackChan
  class Robot
    class Remote
      EXPOSED = [:command, :servo, :led, :face, :text, :torque, :read_pos]

      class Lines < Array
        def write(s)
          push(s)
        end
      end

      def initialize(dispatcher)
        @dispatcher = dispatcher
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
    end
  end
end
