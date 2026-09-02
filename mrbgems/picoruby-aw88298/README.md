# picoruby-aw88298

AW88298 class-D amplifier over I2C (0x36) with mu-law playback over I2S.
`AW88298.ulaw_decode` is C (`src/mruby/aw88298.c`); the rest is `mrblib/aw88298.rb`.

## Usage

```ruby
amp = AW88298.new(i2c: i2c, i2s: I2S.new(sample_rate: 8000))
amp.init_amp(8000)
amp.play_ulaw(ulaw_bytes)   # G.711 mu-law -> signed 16-bit PCM -> I2S
```
