# picoruby-aw88298

AW88298 class-D amplifier over I2C (0x36) with mu-law playback over I2S.
`play_ulaw` decodes with the `ulaw_decode` AOT kernel (`aot/`) on core 1 through
picoruby-multicore, one 2046-byte chunk ahead of the I2S write.

## Usage

```ruby
amp = AW88298.new(i2c: i2c, i2s: I2S.new(sample_rate: 8000))
amp.init_amp(8000)
amp.play_ulaw(ulaw_bytes)
```

`play_ulaw` takes G.711 mu-law bytes and writes signed 16-bit PCM to the I2S.
