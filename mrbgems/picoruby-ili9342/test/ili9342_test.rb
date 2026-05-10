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

  def test_fill_keeps_cs_asserted_across_ramwr_and_pixel_data
    cs = FakeGPIO.new(3)
    spi = FakeSPI.new
    display = ILI9342.new(spi: spi, dc_pin: FakeGPIO.new(2), cs_pin: cs,
                          rst_pin: FakeGPIO.new(4), bl_pin: FakeGPIO.new(5),
                          width: 320, height: 240)
    cs.history.clear
    spi.reset_log!

    display.fill(ILI9342::Color::RED)

    # Locate the RAMWR command in the SPI write log.
    bytes = spi.writes.select { |b| b.is_a?(Integer) }
    ramwr_idx = bytes.index(ILI9342::CMD_RAMWR)
    assert ramwr_idx, "RAMWR (0x2C) must appear in fill SPI log"

    # The CS history is recorded chronologically with the SPI writes interleaved
    # by call order. Simpler invariant: between fill's first @cs.write(0) and
    # final @cs.write(1), CS must NOT pulse high then low again. Count the
    # 1→0 transitions: there should be EXACTLY ONE for the entire RAMWR+pixel
    # phase of fill (not two — one for write_command's CS toggle, one for the
    # bulk write).
    levels = cs.history.map(&:last)
    transitions_to_low = 0
    prev = 1  # CS rests high after init
    levels.each do |v|
      transitions_to_low += 1 if prev == 1 && v == 0
      prev = v
    end
    # set_window in fill calls write_command twice (CASET, RASET), each = 1 transition
    # then RAMWR + pixel data should be a SINGLE transition (currently 2: write_command + manual)
    # So expected after fix: 3 total (CASET, RASET, RAMWR-and-pixels)
    assert_equal 3, transitions_to_low,
                 "fill should toggle CS exactly 3 times: CASET, RASET, RAMWR+pixels combined. Found #{transitions_to_low} (4+ means CS bounced between RAMWR and pixel data — real hardware would discard pixels)"
  end
end

class ILI9342DrawPixelTest < Test::Unit::TestCase
  def setup
    @spi = FakeSPI.new
    @display = ILI9342.new(spi: @spi, dc_pin: FakeGPIO.new(2), cs_pin: FakeGPIO.new(3),
                           rst_pin: FakeGPIO.new(4), bl_pin: FakeGPIO.new(5),
                           width: 320, height: 240)
    @spi.reset_log!
  end

  def test_draw_pixel_sets_window_to_one_pixel_and_writes_two_bytes
    @display.draw_pixel(100, 50, 0xABCD)
    bytes = @spi.writes.select { |b| b.is_a?(Integer) }

    caset_idx = bytes.index(ILI9342::CMD_CASET)
    raset_idx = bytes.index(ILI9342::CMD_RASET)
    ramwr_idx = bytes.index(ILI9342::CMD_RAMWR)

    assert caset_idx, "CASET expected"
    assert_equal [0x00, 0x64, 0x00, 0x64], bytes[caset_idx + 1, 4],
                 "CASET payload must encode x=100..100"
    assert_equal [0x00, 0x32, 0x00, 0x32], bytes[raset_idx + 1, 4],
                 "RASET payload must encode y=50..50"
    payload = bytes[(ramwr_idx + 1)..-1]
    assert_equal [0xAB, 0xCD], payload, "single pixel must be 2 bytes"
  end

  def test_draw_pixel_clips_out_of_range
    @display.draw_pixel(-1, 50, 0xFFFF)
    @display.draw_pixel(320, 50, 0xFFFF)
    @display.draw_pixel(100, -1, 0xFFFF)
    @display.draw_pixel(100, 240, 0xFFFF)
    bytes = @spi.writes.select { |b| b.is_a?(Integer) }
    assert_equal 0, bytes.count(ILI9342::CMD_RAMWR),
                 "out-of-range coords must not write any pixel"
  end
end
