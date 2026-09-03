# picoruby-stackchan-led

12-pixel WS2812 ring on the StackChan CoreS3, driven through the PY32 I/O expander.

## Usage

```ruby
led = StackchanLed.new(py32)           # PY32IOExpander
led.set_brightness(30)
led.animate_side(:left, 255, 0, 0, :blink)   # side: :left / :right / :both, mode: :solid / :blink / :breathing / :off
led.tick(Machine.board_millis)         # call periodically for blink / breathing
```
