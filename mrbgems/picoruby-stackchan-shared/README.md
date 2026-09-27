# picoruby-stackchan-shared

Pure-Ruby layer shared by the StackChan device application and the PC daemon:
the send builder that batches BLE commands into frames, and the BLE error
hierarchy. It depends on `picoruby-stackchan-protocol`'s `Stackchan::BLE::FrameCodec`
for the actual encoding.

## Usage

```ruby
b = Stackchan::BLE::SendBuilder.new
b.face(:joy)
b.led(:red, side: :left, mode: :blink)
b.to_frames                                                     # => ["<F:2>\n", "<L:1,R:255,G:0,B:0,S:R,M:b>\n"]
```

## API

- `Stackchan::BLE::SendBuilder` — collects commands (last write per key wins, first-occurrence order) and emits frames; `led` takes a name from `LED_COLORS`
- `Stackchan::BLE::Error` and subclasses `TimeoutError` / `DeviceError` / `ConnectionError`
