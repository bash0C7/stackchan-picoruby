module StackChan
  class Controller
    class Link
      BUSY_MESSAGE = "robot is held by another controller or unreachable"

      attr_reader :state, :touches
      attr_accessor :on_lost

      def initialize(central:, clock: -> { Machine.board_millis }, hold: nil, keepalive_ms: 7_000, log:)
        @central         = central
        @clock           = clock
        @hold            = hold
        @keepalive_ms    = keepalive_ms
        @log             = log
        @state           = :released
        @touches         = []
        @connects        = 0
        @releases        = 0
        @last_connect_ms = nil
        @last_action_at  = nil
        @last_sent_at    = nil
        @on_lost         = nil
      end

      def generation
        @connects
      end

      def act
        if @state == :held || @state == :quiet
          @central.drain
          lost! if @central.lost?
        end
        connect! if @state == :released || @state == :busy
        begin
          result = yield
        rescue ConnectionError => e
          lost!
          raise e
        rescue TimeoutError => e
          lost! if @central.lost?
          raise e
        end
        lost! if @state != :released && @central.lost?
        used! unless @state == :released
        result
      end

      def tick(expire: true)
        return if @state == :released || @state == :busy
        @central.drain
        if @central.lost?
          lost!
          return
        end
        return if @state == :quiet
        now = @clock.call
        if expire && @hold && now - @last_action_at >= @hold
          @state = :quiet
          @log.call("hold over")
          return
        end
        return if now - @last_sent_at < @keepalive_ms
        @last_sent_at = now
        begin
          @central.keepalive
        rescue ConnectionError => e
          @log.call("keepalive #{e.class}: #{e.message}")
          lost!
        rescue TimeoutError => e
          @log.call("keepalive #{e.class}: #{e.message}")
          if @central.lost?
            lost!
          else
            @state = :quiet
          end
        end
      end

      def lost!
        @central.reset_link
        @state = :released
        @releases += 1
        @touches.clear
        cb = @on_lost
        cb.call if cb
      end

      def listening!
        @last_action_at = @clock.call if @state == :held
      end

      def status
        { link: @state.to_s, connects: @connects, releases: @releases, last_connect_ms: @last_connect_ms, hold_ms: @hold }
      end

      private

      def connect!
        t0 = @clock.call
        begin
          @central.connect
        rescue ConnectionError => e
          @state = :busy
          @log.call("connect #{e.class}: #{e.message}")
          raise Busy, BUSY_MESSAGE
        end
        @connects += 1
        @last_connect_ms = @clock.call - t0
        used!
      end

      def used!
        @state          = :held
        @last_action_at = @clock.call
        @last_sent_at   = @last_action_at
      end
    end
  end
end
