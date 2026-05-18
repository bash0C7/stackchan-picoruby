class FakeLed
  attr_reader :calls

  def initialize
    @calls = []
  end

  def animate_side(side, color, mode)
    @calls << [:animate_side, [side, color, mode]]
  end

  def tick(time_ms)
    @calls << [:tick, [time_ms]]
  end

  def show
    @calls << [:show, []]
  end

  def brightness=(v)
    @calls << [:brightness=, [v]]
  end
end
