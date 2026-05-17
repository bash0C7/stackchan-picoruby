class FakeLed
  attr_reader :animate_side_calls, :tick_calls

  def initialize
    @animate_side_calls = []
    @tick_calls = []
  end

  def animate_side(side, r, g, b, mode)
    @animate_side_calls << [side, r, g, b, mode]
    self
  end

  def tick(now_ms)
    @tick_calls << now_ms
  end

  def last_animate_side_args
    @animate_side_calls.last
  end
end
