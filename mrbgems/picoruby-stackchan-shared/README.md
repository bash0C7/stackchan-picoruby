# picoruby-stackchan-shared

Pure-Ruby layer shared by the StackChan device application and the PC daemon:
BLE frame codec, face / LED color tables, HSB→RGB, and AI subtitle frame text.

## Usage

```ruby
Stackchan::BLE::FrameCodec.encode_face(face_name: :joy)        # => "<F:2>\n"
Stackchan::BLE::FrameCodec.encode_head(yaw_left: 50, yaw_right: nil, pitch_up: 30, time_ms: 500, velocity: nil)
Stackchan::BLE::FrameCodec.parse_ack(".")                       # => :ok
Stackchan::BLE::SendBuilder.new.face(:joy).led(:red).to_frames  # => ["<F:2>\n", "<L:1,...>\n"]
Stackchan::AI::FrameText.build(face_index: "2", text: "こんにちは")
```

## API

- `Stackchan::BLE::FrameCodec` — `encode_face` / `encode_led` / `encode_head` / `encode_torque` / `encode_selftest` / `encode_read_pos` / `parse_ack` / `touch_event?` / `parse_touch`
- `Stackchan::BLE::SendBuilder` — collects commands (last write per key wins, first-occurrence order) and emits frames
- `Stackchan::BLE::FaceTable`, `Stackchan::BLE::LedColorTable`, `Stackchan::BLE::HsbToRgb`
- `Stackchan::BLE::Error` and subclasses `TimeoutError` / `DeviceError` / `ConnectionError`
- `Stackchan::AI::FrameText` — `sanitize` / `build`

## Notes

`:left` / `:right` are from StackChan's own perspective; the wire chars are reversed (`:left` → `"R"`). The table absorbs that.
