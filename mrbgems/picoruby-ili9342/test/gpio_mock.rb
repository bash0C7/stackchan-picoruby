class FakeGPIO
  attr_reader :pin, :history
  attr_accessor :value

  IN  = :in
  OUT = :out
  HIGH = 1
  LOW  = 0

  def initialize(pin, dir = OUT)
    @pin = pin
    @dir = dir
    @value = 0
    @history = []
  end

  def write(v)
    @value = v
    @history << [:write, v]
  end

  def read
    @value
  end

  def high
    write(1)
  end

  def low
    write(0)
  end
end
