module StackChan
  class Robot
    class Ticker
      TOUCH_PERIOD_MS = 50
      LED_PERIOD_MS   = 50
      BLINK_PERIOD_MS = 5000
      BLINK_CLOSED_MS = 150

      def initialize(display:, led:, touch:, dispatcher:, notify:)
        @display    = display
        @led        = led
        @touch      = touch
        @dispatcher = dispatcher
        @notify     = notify
        @touch_at   = nil
        @led_at     = nil
        @blink_at   = nil
        @closed_at  = nil
      end

      def tick(now_ms)
        if due?(@touch_at, now_ms, TOUCH_PERIOD_MS)
          @touch_at = now_ms
          poll_touch
        end
        if due?(@led_at, now_ms, LED_PERIOD_MS)
          @led_at = now_ms
          @led.tick(now_ms)
        end
        blink(now_ms)
      end

      private

      def due?(last, now_ms, period)
        last.nil? || now_ms - last >= period
      end

      def poll_touch
        return unless @touch
        zone = @touch.poll
        return unless zone
        @dispatcher.react_to_touch(zone)
        @notify.call("<touch:#{zone}>\n")
      rescue => e
        puts "[application] touch poll error: #{e.class}: #{e.message}"
      end

      def blink(now_ms)
        @blink_at ||= now_ms
        if @closed_at
          if now_ms - @closed_at >= BLINK_CLOSED_MS
            @dispatcher.current_face_class.new.redraw_eyes_open(@display)
            @closed_at = nil
          end
        elsif now_ms - @blink_at >= BLINK_PERIOD_MS
          @dispatcher.current_face_class.new.redraw_eyes_closed(@display)
          @blink_at  = now_ms
          @closed_at = now_ms
        end
      end
    end
  end
end
