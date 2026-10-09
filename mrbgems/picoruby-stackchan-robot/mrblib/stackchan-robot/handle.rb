module StackChan
  class Robot
    class Handle
      attr_accessor :ticker

      def initialize(dispatcher:, display:, led:, head: nil, speaker: nil)
        @dispatcher = dispatcher
        @display    = display
        @led        = led
        @speaker    = speaker
        @ticker     = nil
      end

      def face(name)
        @dispatcher.show_face(name)
      end

      def led(side, rgb, mode: :solid, flash: nil)
        if flash
          @led.flash_side(side, rgb[0], rgb[1], rgb[2], flash)
        else
          @led.animate_side(side, rgb[0], rgb[1], rgb[2], mode)
        end
        true
      end

      def head(yaw_left: nil, yaw_right: nil, pitch_up: nil, time: 0)
        @dispatcher.move_head(yaw_left, yaw_right, pitch_up, time, 0)
      end

      def text(s)
        @dispatcher.draw_subtitle(s)
      end

      def blink(closed_ms)
        @dispatcher.current_face.redraw_eyes_closed(@display)
        @ticker.reopen_eyes_after(closed_ms)
        true
      end

      def say_ready?
        !@speaker.nil?
      end
    end
  end
end
