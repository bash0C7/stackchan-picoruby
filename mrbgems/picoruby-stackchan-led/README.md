# picoruby-stackchan-led

12-pixel LED driver for the M5Stack StackChan AI Desktop Robot, with built-in 4-mode animation engine. Sits on top of `picoruby-py32-io-expander`.

API style is loosely modeled after [picoruby-ws2812](https://github.com/ksbmyk/picoruby-ws2812) — `fill` / `set_rgb` / `brightness=` / `show` / `clear`. The chip-level WS2812 timing is generated inside the PY32 microcontroller, not on ESP32-S3.

## Installation

Add to your `build_config/xtensa-esp-picoruby.rb`:

```ruby
conf.gem gemdir: '/path/to/mrbgems/picoruby-py32-io-expander'
conf.gem gemdir: '/path/to/mrbgems/picoruby-stackchan-led'
```

## Quick start

```ruby
require 'i2c'
require 'py32_io_expander'
require 'stackchan_led'

i2c = I2C.new(unit: :ESP32_I2C0, frequency: 400_000, sda_pin: 12, scl_pin: 11)
py32 = PY32IOExpander.new(i2c)
led = StackchanLed.new(py32)

led.fill(255, 0, 0).show       # all red
led.brightness = 50
led.fill(0, 255, 0).show       # all green at 50%

# Animation
led.animate(0, 255, 0, :breathing)
loop do
  led.tick(Machine.uptime_us / 1000)
  sleep_ms 50
end
```

## Animation modes

| Mode | Behavior |
|---|---|
| `:solid` | static color, immediate apply |
| `:blink` | 1Hz on/off (500ms each phase) |
| `:breathing` | 3-second cycle, 12-step intensity LUT |
| `:off` | clear, immediate apply |

## API

| Method | Description |
|---|---|
| `StackchanLed.new(py32)` | Wraps a `PY32IOExpander`. Sets LED count to 12, blanks the strip. |
| `fill(r, g, b)` | Sets all pixels. Returns self. |
| `set_rgb(i, r, g, b)` | Sets one pixel by index. Returns self. |
| `brightness=(v)` | 0-100, clamped. Applies to all subsequent `show`. |
| `clear` | Same as `fill(0, 0, 0)`. |
| `show` | Push current buffer to PY32 (with brightness applied). |
| `animate(r, g, b, mode)` | Set color + animation mode. Solid/off apply immediately; blink/breathing render on next `tick`. |
| `tick(now_ms)` | Advance the animator. Pass `Machine.uptime_us / 1000` from the main task. |

`now_ms` MUST come from the main task (calling `Machine.uptime_us` from a background `Task` causes silent task death on mruby/c).

## References

- Spec: `docs/superpowers/specs/2026-05-14-stackchan-led-protocol-extension-design.md`
- Layout reference: [picoruby-mpu6886](https://github.com/bash0C7/picoruby-mpu6886)
- API inspiration: [picoruby-ws2812](https://github.com/ksbmyk/picoruby-ws2812)

## License

MIT
