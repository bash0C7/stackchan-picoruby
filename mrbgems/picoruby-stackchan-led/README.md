# picoruby-stackchan-led

12-pixel WS2812 ring on the StackChan CoreS3, driven through the PY32 I/O expander.

## Usage

```ruby
led = StackchanLed.new(py32)
led.animate_side(:left, 255, 0, 0, :blink)
led.flash_side(:both, 0, 255, 0)
led.tick(Machine.uptime_us / 1000)
```

`side` is `:left`, `:right` or `:both`; `mode` is `:solid`, `:blink`, `:breathing` or `:off`.
`flash_side` lights a side solid and blanks it 300 ms later unless `animate_side` sets that side first.
`tick` drives blink, breathing and the end of a flash.
