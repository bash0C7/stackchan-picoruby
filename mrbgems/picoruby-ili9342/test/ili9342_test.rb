require "test_helper"
require "ili9342"

class HarnessTest < Test::Unit::TestCase
  def test_fake_spi_records_writes
    spi = FakeSPI.new
    spi.write(0xAB, 0xCD)
    assert_equal [0xAB, 0xCD], spi.writes
  end

  def test_fake_gpio_records_history
    gpio = FakeGPIO.new(17)
    gpio.high
    gpio.low
    assert_equal [[:write, 1], [:write, 0]], gpio.history
  end
end
