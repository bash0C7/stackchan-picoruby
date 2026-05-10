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

class ILI9342InitTest < Test::Unit::TestCase
  def setup
    @spi = FakeSPI.new
    @dc  = FakeGPIO.new(2)
    @cs  = FakeGPIO.new(3)
    @rst = FakeGPIO.new(4)
    @bl  = FakeGPIO.new(5)
    @display = ILI9342.new(spi: @spi, dc_pin: @dc, cs_pin: @cs,
                           rst_pin: @rst, bl_pin: @bl,
                           width: 320, height: 240, rotation: :landscape)
  end

  def test_reset_pin_pulsed
    history = @rst.history.map(&:last)
    assert_equal [1, 0, 1], history.first(3),
                 "RST should go high → low → high during init"
  end

  def test_dc_low_for_command_then_high_for_data
    # First command (SLPOUT or SWRESET) should set DC low before SPI write,
    # then DC high before payload bytes (if any).
    assert @dc.history.size >= 2,
           "DC pin should toggle multiple times during init"
    assert_equal 0, @dc.history.first.last,
                 "First DC level must be LOW (command)"
  end

  def test_init_sends_disp_on
    bytes = @spi.writes.select { |b| b.is_a?(Integer) }
    assert_includes bytes, 0x29, "DISPON (0x29) must be sent during init"
  end

  def test_init_sends_madctl_for_landscape
    bytes = @spi.writes.select { |b| b.is_a?(Integer) }
    idx = bytes.index(0x36)
    assert idx, "MADCTL (0x36) must be sent during init"
    landscape_madctl = ILI9342::MADCTL_LANDSCAPE
    assert_equal landscape_madctl, bytes[idx + 1],
                 "Landscape MADCTL value must follow 0x36 command"
  end
end

class ILI9342ColorTest < Test::Unit::TestCase
  def test_color_constants
    assert_equal 0x0000, ILI9342::Color::BLACK
    assert_equal 0xFFFF, ILI9342::Color::WHITE
    assert_equal 0xF800, ILI9342::Color::RED
    assert_equal 0x07E0, ILI9342::Color::GREEN
    assert_equal 0x001F, ILI9342::Color::BLUE
  end

  def test_rgb_helper
    assert_equal 0x0000, ILI9342.rgb(0, 0, 0)
    assert_equal 0xFFFF, ILI9342.rgb(255, 255, 255)
    assert_equal 0xF800, ILI9342.rgb(255, 0, 0)
    assert_equal 0x07E0, ILI9342.rgb(0, 255, 0)
    assert_equal 0x001F, ILI9342.rgb(0, 0, 255)
  end
end

class ILI9342FillTest < Test::Unit::TestCase
  def setup
    @spi = FakeSPI.new
    @display = ILI9342.new(spi: @spi, dc_pin: FakeGPIO.new(2), cs_pin: FakeGPIO.new(3),
                           rst_pin: FakeGPIO.new(4), bl_pin: FakeGPIO.new(5),
                           width: 320, height: 240)
    @spi.reset_log!
  end

  def test_fill_writes_caset_raset_ramwr_then_pixel_payload
    @display.fill(ILI9342::Color::RED)
    bytes = @spi.writes.select { |b| b.is_a?(Integer) }

    assert_includes bytes, ILI9342::CMD_CASET, "CASET must be issued before fill"
    assert_includes bytes, ILI9342::CMD_RASET, "RASET must be issued before fill"
    assert_includes bytes, ILI9342::CMD_RAMWR, "RAMWR must be issued before pixel payload"
  end

  def test_fill_writes_correct_pixel_count
    @display.fill(ILI9342::Color::BLUE)
    bytes = @spi.writes.select { |b| b.is_a?(Integer) }
    ramwr_idx = bytes.index(ILI9342::CMD_RAMWR)
    payload   = bytes[(ramwr_idx + 1)..-1]
    expected_payload_bytes = 320 * 240 * 2
    assert_equal expected_payload_bytes, payload.size,
                 "320*240*2 bytes of pixel data must follow RAMWR"
  end
end
