module StackChan
  class Robot
    # The 20 ms link loop: pops one BLE event, services the dRuby channel, releases an idle central and ticks the Ticker.
    class LinkLoop
      TICK_MS = 20
      CCCD_NOTIFY = "\x01\x00"

      # @rbs!
      #   interface _Port
      #     def pop_event: (timeout_ms: Integer) -> (String | Symbol)?
      #     def event_popped: () -> void
      #     def take_write: (Integer handle) -> String?
      #     def send_notification: (Integer handle, String frame) -> void
      #     def disconnect_central: () -> void
      #   end
      # @rbs @port: _Port
      # @rbs @ticker: Ticker
      # @rbs @on_packet: ^(String) -> void
      # @rbs @clock: ^() -> Integer
      # @rbs @drb: DrbChannel
      # @rbs @remote: Remote
      # @rbs @release_after_us: Integer?
      # @rbs @active_at: Integer?

      # Stores the collaborators. release_after (ms) enables idle release; clock returns microseconds.
      #: (port: _Port, ticker: Ticker, on_packet: ^(String) -> void, clock: ^() -> Integer, drb: DrbChannel, remote: Remote, ?release_after: Integer?) -> void
      def initialize(port:, ticker:, on_packet:, clock:, drb:, remote:, release_after: nil)
        @port        = port
        @ticker      = ticker
        @on_packet   = on_packet
        @clock       = clock
        @drb         = drb
        @remote      = remote
        @release_after_us = release_after && release_after * 1000
        @active_at = nil
      end

      # Runs one loop iteration. dRuby traffic and audio playback refresh the activity time of a connected central.
      #: () -> void
      def tick
        event = @port.pop_event(timeout_ms: TICK_MS)
        @port.event_popped
        @on_packet.call(event) if event.is_a?(String)
        @active_at = @clock.call if @drb.service(@port)
        release_if_idle
        @ticker.tick(@clock.call / 1000)
        @active_at = @clock.call if @remote.perform_audio_play && @active_at
      end

      # Starts the idle timer for a newly arrived central.
      #: () -> Integer
      def central_arrived
        @active_at = @clock.call
      end

      # Stops the idle timer and resets the dRuby channel.
      #: () -> void
      def disconnected
        @active_at = nil
        @drb.disconnected
      end

      private

      # Disconnects the central once it has been idle for release_after.
      #: () -> void
      def release_if_idle
        return unless @release_after_us && @active_at
        return if @clock.call - @active_at < @release_after_us
        @active_at = nil
        @port.disconnect_central
      end
    end
  end
end
