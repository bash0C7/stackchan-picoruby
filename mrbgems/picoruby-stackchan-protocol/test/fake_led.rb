class FakeLed
  attr_reader :animate_calls, :tick_calls

  def initialize
    @animate_calls = []
    @tick_calls = []
  end

  def animate(r, g, b, mode)
    @animate_calls << [r, g, b, mode]
    self
  end

  def tick(now_ms)
    @tick_calls << now_ms
  end

  def last_animate_args
    @animate_calls.last
  end
end
