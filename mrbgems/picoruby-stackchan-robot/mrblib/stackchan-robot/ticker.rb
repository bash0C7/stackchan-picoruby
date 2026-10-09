module StackChan
  class Robot
    class Ticker
      TOUCH_PERIOD_MS = 50
      LED_PERIOD_MS   = 50

      def initialize(display:, led:, touch:, dispatcher:, remote:, touch_handlers: {}, periodic: [])
        @display        = display
        @led            = led
        @touch          = touch
        @dispatcher     = dispatcher
        @remote         = remote
        @touch_handlers = touch_handlers
        @periodic       = periodic
        @periodic_due   = []
        @robot_handle   = dispatcher.robot_handle
        @robot_handle.ticker = self
        @now_ms         = 0
        @touch_at       = nil
        @led_at         = nil
        @open_at        = nil
      end

      def tick(now_ms)
        @now_ms = now_ms
        if due?(@touch_at, now_ms, TOUCH_PERIOD_MS)
          @touch_at = now_ms
          poll_touch
        end
        if due?(@led_at, now_ms, LED_PERIOD_MS)
          @led_at = now_ms
          @led.tick(now_ms)
        end
        reopen_eyes(now_ms)
        run_periodic(now_ms)
      end

      def reopen_eyes_after(closed_ms)
        @open_at = @now_ms + closed_ms
      end

      private

      def due?(last, now_ms, period)
        last.nil? || now_ms - last >= period
      end

      def poll_touch
        return unless @touch
        zone = @touch.poll
        return unless zone
        handler = @touch_handlers[zone]
        handler.call(@robot_handle) if handler
        @remote.push_touch(zone)
      rescue => e
        puts "[application] touch poll error: #{e.class}: #{e.message}"
      end

      def reopen_eyes(now_ms)
        return unless @open_at && now_ms >= @open_at
        @open_at = nil
        @dispatcher.current_face.redraw_eyes_open(@display)
      end

      def run_periodic(now_ms)
        i = 0
        while i < @periodic.size
          entry = @periodic[i]
          due = @periodic_due[i]
          if due.nil?
            @periodic_due[i] = now_ms + entry[0]
          elsif now_ms >= due
            @periodic_due[i] = now_ms + entry[0]
            call_periodic(entry[1])
          end
          i += 1
        end
      end

      def call_periodic(handler)
        handler.call(@robot_handle)
      rescue => e
        puts "[application] periodic error: #{e.class}: #{e.message}"
      end
    end
  end
end
