# picoruby-py32-io-expander

PY32 IO Expander driver for the M5Stack StackChan AI Desktop Robot (M5Stack 11129) base unit.

The PY32 chip is an I2C device at address `0x6F` that wraps an internal WS2812-style LED controller (12 pixels at REG `0x30`+) and 16 GPIO pins (P0-P15). Used by the StackChan AI base for the eye-row LED ring and servo power switching.

This gem is a pure-Ruby PicoRuby Runtime Gem. It does NOT generate WS2812 timing on the host — it writes color data over I2C and lets the PY32 chip do the bit-banging. There is no GPIO data line for WS2812 protocol exposed on ESP32-S3 in this hardware.

## Installation

Add to your `build_config/xtensa-esp-picoruby.rb`:

```ruby
conf.gem gemdir: '/path/to/mrbgems/picoruby-py32-io-expander'
```

Depends on `picoruby-i2c`.

## Quick start

```ruby
require 'i2c'
require 'py32_io_expander'

i2c = I2C.new(unit: :ESP32_I2C0, frequency: 400_000, sda_pin: 12, scl_pin: 11)
py32 = PY32IOExpander.new(i2c)

py32.set_led_count(12)
py32.write_led_ram(Array.new(12) { [255, 0, 0] })  # all red
py32.refresh_leds
```

## API

| Method | Description |
|---|---|
| `PY32IOExpander.new(i2c)` | Wraps an I2C instance. Address `0x6F` is fixed. |
| `set_led_count(n)` | Tells the chip how many LEDs to drive. Writes to REG `0x25`. |
| `write_led_ram(pixels)` | `pixels` = `[[r,g,b], ...]`. Packs to RGB565 big-endian, bulk-writes starting at REG `0x30`. |
| `refresh_leds` | Latches the LED RAM into the WS2812 output. Sets bit 6 of REG `0x24`. |

All methods raise `IOError` on I2C failure.

## References

- Authoritative register map: `M5Stack/StackChan/firmware/main/hal/drivers/PY32IOExpander_Class/PY32IOExpander_Class.cpp` line 46-47, line 338-360
- Spec: `docs/superpowers/specs/2026-05-14-stackchan-led-protocol-extension-design.md`
- Layout reference: [picoruby-mpu6886](https://github.com/bash0C7/picoruby-mpu6886)

## License

MIT
