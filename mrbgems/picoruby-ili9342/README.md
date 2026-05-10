# picoruby-ili9342

ILI9342 LCD controller driver for PicoRuby. Pure Ruby implementation on top of `picoruby-spi` and `picoruby-gpio`.

## Status

Work in progress. Initial target: M5Stack CoreS3 (320×240, landscape).

## Usage

CoreS3 pin numbers are baked into the example below. For other ESP32-S3 boards, substitute pin numbers per your wiring; see `docs/cores3-pinout-and-init.md` for the reference layout.

```ruby
require 'spi'
require 'gpio'
require 'ili9342'

# CoreS3 pins (verified against m5stack/StackChan upstream)
spi = SPI.new(unit: :ESP32_SPI3_HOST, frequency: 40_000_000,
              sck_pin: 36, copi_pin: 37, cs_pin: 3, mode: 2)
display = ILI9342.new(
  spi: spi,
  dc_pin:  GPIO.new(35, GPIO::OUT),
  cs_pin:  GPIO.new(3,  GPIO::OUT),
  rst_pin: GPIO.new(1,  GPIO::OUT),  # placeholder — RST is on AW9523 IO Expander
  bl_pin:  GPIO.new(2,  GPIO::OUT),  # placeholder — BL is on AXP2101 PMIC
  width: 320, height: 240, rotation: :landscape
)

display.fill(ILI9342::Color::BLACK)
display.draw_rect(10, 10, 50, 30, ILI9342::Color::GREEN, fill: true)
```

> [!NOTE]
> On real CoreS3 hardware the LCD reset and backlight lines are routed through the AW9523 IO Expander and AXP2101 PMIC respectively, not direct GPIOs. The placeholders above let `ILI9342.new` complete; software SWRESET (init cmd 0x01) substitutes for HW reset, and USB power keeps the backlight on. A future `picoruby-aw9523` driver would let `rst_pin:` accept a real AW9523-port object.

## Examples

See `examples/` for `black_fill.rb`, `color_cycle.rb`, `face_neutral.rb`, `face_smile.rb`, `face_joy.rb`, `avatar_demo.rb`.

## Performance baseline (CoreS3, mruby VM, 40 MHz SPI)

| Operation | Avg over 5 runs |
| --- | --- |
| `fill()` full-screen 320×240 | _TBD — pending hardware run of `examples/benchmark_fill.rb`_ |

Measured by `examples/benchmark_fill.rb`. If `fill` becomes a bottleneck for animation, the chunked-write path is the C-port candidate (see future spec).
