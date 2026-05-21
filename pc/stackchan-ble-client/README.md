# stackchan-ble-client

BLE control SDK for the M5Stack StackChan running PicoRuby firmware (see [stackchan-picoruby](https://github.com/bash0C7/stackchan-picoruby)). Connects via Nordic UART Service and exposes a block-DSL for face / LED frames with left/right side support and four color forms (named symbol, RGB hex, HSB hex, mode keyword).

## Requirements

- Ruby ≥ 3.1
- Mac with Bluetooth (CoreBluetooth)
- [rb-corebluetooth-mac](https://github.com/bash0C7/rb-corebluetooth-mac) (path-loaded — see `Gemfile`)
- The StackChan device running `examples/application.rb` (advertises as `StackChan-PicoRuby`)

## Quick start

```ruby
require "stackchan_ble_client"

client = StackchanBleClient::Client.new(device_name: "StackChan-PicoRuby")
client.connect

client.send do |stackchan|
  stackchan.face(:joy)
  stackchan.led(:red, mode: :blink)
end

client.send do |stackchan|
  stackchan.led(:blue, side: :left)
  stackchan.led(:green, side: :right)
end

client.send do |stackchan|
  stackchan.led(:rgb, 0xFF8000)             # 24-bit RGB packed
  stackchan.led(:hsb, 0x00FFFF, side: :left)  # 24-bit HSB packed (H/S/B each 0-255)
end

client.disconnect
```

### Block DSL aggregation rules

- `face` is a single key; calling `stackchan.face(...)` multiple times within one block uses the last one.
- `led` is keyed by `(side)` — `:left` / `:right` / `:both` are independent; each defaults to the last call for that side. `:left` / `:right` are from **StackChan's own perspective** (its left / right hand); the wire chars are swapped internally to match the device firmware.
- Within one `#send` block, up to 4 frames are emitted: `face` + one per side that was touched.
- Frames are emitted in the order each key was first mentioned in the block.
- ACK is 1 byte from the device per frame (`.` = OK, `?` = error → `DeviceError` raised).

## CLI

```bash
bundle exec stackchan-ble-control face joy
bundle exec stackchan-ble-control led red blink --side left
bundle exec stackchan-ble-control led-rgb 0xFF8000 --mode blink
bundle exec stackchan-ble-control led-hsb 0x00FFFF --side right
bundle exec stackchan-ble-control combo --face joy --led 'red blink'
bundle exec stackchan-ble-control --yaw-left 50 --pitch-up 30 --time 500 servo
bundle exec stackchan-ble-control torque on
bundle exec stackchan-ble-control selftest
bundle exec stackchan-ble-control calibrate --align-only
bundle exec stackchan-ble-control calibrate --samples 3 --format ruby
bundle exec stackchan-ble-control raw '<F:0>'
```

`servo` / `torque` / `selftest` / `calibrate` operate the head servos via BLE. `calibrate --align-only` is the daily startup flow (torque off → operator aligns forward → torque on). `calibrate` without `--align-only` runs the 5-pose anchor recalibration and prints `SERVO_*_ZERO` / `RANGE_RAW` constants for paste into `application.rb`.

Exit codes:

| code | meaning |
|---|---|
| 0 | success |
| 2 | adapter (CoreBluetooth state error) |
| 3 | timeout (scan / connect / ACK) |
| 4 | connection (lost or refused) |
| 5 | assertion (unknown face name, device rejected with `?` ACK) |
| 6 | calibration needed (device returned `unknown` on `<read:pos>` / actual servo position) |
| 7 | calibration incomplete (verify pose Δ exceeded fail tolerance, or operator aborted) |
| 9 | uncategorized |

## License

MIT
