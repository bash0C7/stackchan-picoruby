module StackChan
  class Robot
    # Runs the periodic work of the robot: touch polling, LED animation, eye reopening and app periodic handlers.
    class Ticker
      TOUCH_PERIOD_MS = 50
      LED_PERIOD_MS   = 50

      # @rbs @display: _Display
      # @rbs @led: StackchanLed
      # @rbs @touch: Si12T?
      # @rbs @dispatcher: Dispatcher
      # @rbs @remote: Remote
      # @rbs @touch_handlers: Hash[Integer, touch_handler]
      # @rbs @periodic: Array[[Integer, periodic_handler]]
      # @rbs @periodic_due: Array[Integer?]
      # @rbs @robot_handle: Handle
      # @rbs @now_ms: Integer
      # @rbs @touch_at: Integer?
      # @rbs @led_at: Integer?
      # @rbs @open_at: Integer?

      # Stores the collaborators and registers itself on the dispatcher's robot handle.
      #: (display: _Display, led: StackchanLed, touch: Si12T?, dispatcher: Dispatcher, remote: Remote, ?touch_handlers: Hash[Integer, touch_handler], ?periodic: Array[[Integer, periodic_handler]]) -> void
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

      # Runs whatever is due at now_ms (milliseconds): touch poll and LED tick every 50 ms, eye reopening, periodic handlers.
      #: (Integer now_ms) -> void
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

      # Schedules the eyes to be redrawn open closed_ms after the last tick time.
      #: (Integer closed_ms) -> Integer
      def reopen_eyes_after(closed_ms)
        @open_at = @now_ms + closed_ms
      end

      private

      # Returns true when last is nil or period ms have passed since last.
      #: (Integer? last, Integer now_ms, Integer period) -> bool
      def due?(last, now_ms, period)
        last.nil? || now_ms - last >= period
      end

      # Polls the touch sensor; calls the zone's handler and queues the zone on the Remote. Logs errors and continues.
      #: () -> nil
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

      # Redraws the current face with open eyes once the scheduled time has passed.
      #: (Integer now_ms) -> void
      def reopen_eyes(now_ms)
        return unless @open_at && now_ms >= @open_at
        @open_at = nil
        @dispatcher.current_face.redraw_eyes_open(@display)
      end

      # Calls each periodic handler whose interval has elapsed; the first call is one interval after the first tick.
      #: (Integer now_ms) -> void
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

      # Calls handler with the robot handle. Logs errors and continues.
      #: (periodic_handler handler) -> void
      def call_periodic(handler)
        handler.call(@robot_handle)
      rescue => e
        puts "[application] periodic error: #{e.class}: #{e.message}"
      end
    end
  end
end
