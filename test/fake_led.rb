class FakeLed
  attr_reader :calls

  def initialize
    @calls = []
  end

  def animate_side(side, r, g, b, mode)
    @calls << [:animate_side, [side, r, g, b, mode]]
    self
  end

  def flash_side(side, r, g, b, duration_ms = 300)
    @calls << [:flash_side, [side, r, g, b, duration_ms]]
    self
  end

  def tick(now_ms)
    @calls << [:tick, [now_ms]]
  end

  def show
    @calls << [:show, []]
    self
  end
end
