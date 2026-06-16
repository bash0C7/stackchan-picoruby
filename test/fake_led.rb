class FakeLed
  attr_reader :calls

  def initialize
    @calls = []
  end

  # Mirrors StackchanLed#animate_side(side, r, g, b, mode) — the Dispatcher
  # calls this with separated r/g/b ints, not a packed color.
  def animate_side(side, r, g, b, mode)
    @calls << [:animate_side, [side, r, g, b, mode]]
    self
  end

  def tick(now_ms)
    @calls << [:tick, [now_ms]]
  end

  def show
    @calls << [:show, []]
    self
  end

  def brightness=(v)
    @calls << [:brightness=, [v]]
  end
end
