module StackChan
  class Robot
    # The robot API passed to app callbacks (touch, periodic, boot, remote handlers).
    # Forwards to the Dispatcher, the LED driver and the Ticker.
    class Handle
      # @rbs @dispatcher: Dispatcher
      # @rbs @display: _Display
      # @rbs @led: StackchanLed
      # @rbs @speaker: AW88298?
      # @rbs @ticker: Ticker?

      attr_accessor :ticker #: Ticker?

      # Stores the collaborators. head: is accepted and not stored.
      #: (dispatcher: Dispatcher, display: _Display, led: StackchanLed, ?head: Head?, ?speaker: AW88298?) -> void
      def initialize(dispatcher:, display:, led:, head: nil, speaker: nil)
        @dispatcher = dispatcher
        @display    = display
        @led        = led
        @speaker    = speaker
        @ticker     = nil
      end

      # Shows the named face. Returns false when the face is not defined.
      #: (Symbol name) -> bool
      def face(name)
        @dispatcher.show_face(name)
      end

      # Sets the LED animation for a side, or flashes it when flash: (ms) is given. Returns true.
      #: (StackchanLed::side side, Array[Integer] rgb, ?mode: StackchanLed::mode, ?flash: Integer?) -> bool
      def led(side, rgb, mode: :solid, flash: nil)
        if flash
          @led.flash_side(side, rgb[0], rgb[1], rgb[2], flash)
        else
          @led.animate_side(side, rgb[0], rgb[1], rgb[2], mode)
        end
        true
      end

      # Moves the head to normalized 0..100 positions over time ms. Returns false for out-of-range or empty requests.
      #: (?yaw_left: Integer?, ?yaw_right: Integer?, ?pitch_up: Integer?, ?time: Integer) -> bool
      def head(yaw_left: nil, yaw_right: nil, pitch_up: nil, time: 0)
        @dispatcher.move_head(yaw_left, yaw_right, pitch_up, time, 0)
      end

      # Draws s as the subtitle band. Returns false when s is nil.
      #: (String? s) -> bool
      def text(s)
        @dispatcher.draw_subtitle(s)
      end

      # Draws the current face with closed eyes and schedules them to reopen after closed_ms. Returns true.
      #: (Integer closed_ms) -> bool
      def blink(closed_ms)
        @dispatcher.current_face.redraw_eyes_closed(@display)
        @ticker.reopen_eyes_after(closed_ms)
        true
      end

      # Returns true when a speaker is attached.
      #: () -> bool
      def say_ready?
        !@speaker.nil?
      end
    end
  end
end
