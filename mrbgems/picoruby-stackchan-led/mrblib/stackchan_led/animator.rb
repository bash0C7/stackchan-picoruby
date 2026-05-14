class StackchanLed
  class Animator
    def initialize(led)
      @led = led
      @r = 0
      @g = 0
      @b = 0
      @mode = :off
      @phase_start_ms = nil
    end

    def set(r, g, b, mode)
      @r = r
      @g = g
      @b = b
      @mode = mode
      @phase_start_ms = nil
      apply_immediately
    end

    def tick(now_ms)
      return unless dynamic?
      @phase_start_ms ||= now_ms
      # blink and breathing implementations land in later tasks
    end

    private

    def dynamic?
      @mode == :blink || @mode == :breathing
    end

    def apply_immediately
      case @mode
      when :solid
        @led.fill(@r, @g, @b).show
      when :off
        @led.clear.show
      end
    end
  end
end
