# picoruby-ili9342

ILI9342 LCD controller driver for PicoRuby. Pure Ruby implementation on top of `picoruby-spi` and `picoruby-gpio`.

## Status

Work in progress. Initial target: M5Stack CoreS3 (320×240, landscape).

## Usage

```ruby
require 'spi'
require 'gpio'
require 'ili9342'

spi = SPI.new(unit: :ESP32_SPI2_HOST, frequency: 40_000_000,
              sck_pin: <SCK>, copi_pin: <MOSI>, cs_pin: <CS>, mode: 0)
display = ILI9342.new(
  spi: spi, dc_pin: <DC>, cs_pin: <CS>, rst_pin: <RST>, bl_pin: <BL>,
  width: 320, height: 240, rotation: :landscape
)

display.fill(ILI9342::Color::BLACK)
display.draw_rect(10, 10, 50, 30, ILI9342::Color::GREEN, fill: true)
```

Replace `<SCK>` etc. with concrete CoreS3 pin numbers from `docs/cores3-pinout-and-init.md`.

## Examples

See `examples/` for `black_fill.rb`, `color_cycle.rb`, `face_neutral.rb`, `face_smile.rb`, `face_joy.rb`, `avatar_demo.rb`.
