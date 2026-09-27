# picoruby-stackchan-shared

Pure-Ruby layer shared by the StackChan device application and the PC daemon:
the BLE frame codec with its face and LED colour tables, and the AI subtitle
frame text.

## Usage

```ruby
Stackchan::BLE::FrameCodec.encode_face(face_name: :joy)        # => "<F:2>\n"
Stackchan::BLE::FrameCodec.encode_head(yaw_left: 50, yaw_right: nil, pitch_up: 30, time_ms: 500, velocity: nil)
b = Stackchan::BLE::SendBuilder.new
b.face(:joy)
b.led(:red, side: :left, mode: :blink)
b.to_frames                                                     # => ["<F:2>\n", "<L:1,R:255,G:0,B:0,S:R,M:b>\n"]
Stackchan::AI::FrameText.build(face_index: "2", text: "こんにちは")
```

## API

- `Stackchan::BLE::FrameCodec` — `encode_face` / `encode_led` / `encode_head` / `encode_torque` / `encode_selftest` / `encode_read_pos` / `touch_event?` / `parse_touch`, and the `FACE_INDICES` table
- `Stackchan::BLE::SendBuilder` — collects commands (last write per key wins, first-occurrence order) and emits frames; `led` takes a name from `LED_COLORS`
- `Stackchan::BLE::Error` and subclasses `TimeoutError` / `DeviceError` / `ConnectionError`
- `Stackchan::AI::FrameText` — `sanitize` / `build`

## Notes

`:left` / `:right` are from StackChan's own perspective; the wire chars are reversed (`:left` → `"R"`). `FrameCodec::SIDE_TO_CHAR` absorbs that.
