# stackchan-picoruby

A personal port of [Stack-chan](https://github.com/stack-chan/stack-chan) to
[PicoRuby](https://github.com/picoruby/picoruby), running on
[R2P2-ESP32](https://github.com/picoruby/R2P2-ESP32) on the
[M5Stack StackChan AI Desktop Robot (CoreS3)](https://www.switch-science.com/products/11129).
It is a work in progress; APIs, protocols, and the build flow can change.

Stack-chan is a robot for the M5Stack platform, created by Shinya Ishikawa and
the Stack-chan community.

## Acknowledgement

- The [Stack-chan](https://github.com/stack-chan/stack-chan) project by Shinya
  Ishikawa and the community for the hardware design, the face, and the
  concept. The official C++ firmware (referenced read-only as `../StackChan`)
  is the source for pin assignments and cold-boot sequences.
- [PicoRuby](https://github.com/picoruby/picoruby) by
  [@hasumikin](https://github.com/hasumikin) and contributors.
- [R2P2-ESP32](https://github.com/picoruby/R2P2-ESP32) for the ESP32 port.

## Architecture

```
+-----------+   BLE NUS (frame protocol + ACK queue)   +---------------------+
|  macOS    | <--------------------------------------> |  CoreS3 / R2P2      |
|  (Ruby    |                                          |  PicoRuby + mrbgems |
|  client)  |                                          |  LCD / LED / servo  |
+-----------+                                          |  / BLE / speaker    |
                                                       +---------------------+
```

The CoreS3 is an I/O endpoint. It renders faces, drives the 12-pixel WS2812 RGB
ring, moves the two feedback servos, plays audio through the AW88298 amplifier,
advertises the Nordic UART Service, and listens for control frames.

The macOS side is the orchestrator. It sends control frames (face, LED, servo
position, audio) and reads single-byte ACK or ERR replies plus detail frames.

Control frames are key-value, semicolon-delimited, parsed by the FrameParser in
the `picoruby-stackchan-protocol` gem. Audio is sent as a length-prefixed
`<A:nbytes>` frame followed by raw mu-law bytes in MTU-sized writes.

## Code layout

The hardware drivers are standalone PicoRuby mrbgems, each in its own sibling
repository rather than an in-tree `mrbgems/` directory:

```
../picoruby-ili9342/              LCD driver
../picoruby-py32-io-expander/     PY32 I/O expander (LEDs, VM_EN)
../picoruby-scservo/              feedback servo (yaw + pitch)
../picoruby-stackchan-protocol/   frame protocol FrameParser
../picoruby-i2s/                  I2S TX for the speaker
```

The firmware build wires these into R2P2-ESP32. All StackChan business logic
lives in a single autostart payload:

```
app/application.rb   Face rendering, the WS2812 LED ring driver, the command
                     dispatcher, the BLE peripheral, audio receive, and the
                     cold-boot init sequence.

pc/stackchan/              Unified macOS-side CLI (`stackchan <verb>`) backed
                           by an auto-spawn daemon. Internal modules:
                           Stackchan::{BLE, Voice, AI, Event, Display}.

test/                      Host tests (picotest on a host PicoRuby VM).
lib/ruby_class_extract.rb  prism-AST loader for application.rb class bodies.
lib/deploy/                host-side picomodem uploader.
Rakefile                   build, flash, deploy, and BLE smoke task wrappers.
```

Host tests run the device-side logic on a host PicoRuby VM through picotest. A
CRuby orchestrator extracts the class bodies from `application.rb` with a prism
AST so the device classes can be exercised without the device. Device
interaction (build, flash, deploy, capture) goes through the
`stackchan-device-*` skills, which wrap the `r2p2:*` Rakefile tasks.

## Quickstart (macOS side)

A single CLI `stackchan` drives the robot. The first call auto-spawns a
persistent daemon (`stackchand`) that holds the BLE link and the
Foundation Model session; subsequent calls reuse it.

```bash
cd pc/stackchan
bundle install   # first time only

bundle exec exe/stackchan status                   # auto-spawn daemon + show link state
bundle exec exe/stackchan face joy                 # neutral / smile / joy / surprised / sad / angry / closed
bundle exec exe/stackchan led both red solid       # side: left|right|both, mode: solid|blink|breathing|off
bundle exec exe/stackchan servo --yaw-left 50 --pitch-up 30 --time 500
bundle exec exe/stackchan torque on                # off lets you move the head by hand
bundle exec exe/stackchan say "ぼくスタックチャンだよ" --gain 0.1
bundle exec exe/stackchan chat "おはよう"          # Apple Foundation Model reply + face + subtitle
bundle exec exe/stackchan stop                     # shut the daemon down
```

### Interactive consoles

- `stackchan repl` — single-terminal operator console: type any verb at
  the prompt, and touch events stream inline as `[touch] zone=N`. Use
  this when you want to observe head-touch and drive face / say / chat
  in the same session.
- `stackchan tui`  — interactive servo TUI with short commands
  (`yl 50`, `pu 30`, `fwd`, `ton` / `toff`, `face joy`, ...).

### Calibration

```bash
bundle exec exe/stackchan calibrate --align-only   # daily startup: torque off → align forward → torque on
bundle exec exe/stackchan calibrate --samples 5 --format ruby   # full 5-pose anchor recal, prints constants
```

## Capabilities

| Subsystem | State | Notes |
|---|---|---|
| Faces (Neutral, Smile, Joy, Surprised, Sad, Angry) | yes | photo-derived geometry |
| Closed face | yes | torque-off idle indicator, not an emotion |
| Eye-blink animation | yes | eye-only redraw |
| WS2812 LED ring (12 px) | yes | solid, blink, breathing, off, per side |
| Servo control (yaw, pitch) | yes | normalized YL/YR/PU protocol, BLE calibration CLI |
| BLE control (Nordic UART Service) | yes | RX/TX, ACK queue, heartbeat tick |
| Speaker (AW88298 over I2S) | yes | mu-law audio streamed from macOS over BLE |
| Microphone | no | planned |
| IMU (BMI270 + BMM150) | no | planned |
| 3-zone head touch (Si12T) | no | planned |
| WiFi, HTTP, MQTT, WebSocket | no | gems available, wiring pending |
| Camera (GC0308) | no | deferred |
| NFC | no | deferred |

## Audio path

macOS synthesizes speech with `say`, converts it to 8 kHz mono PCM, encodes it
to G.711 mu-law, and streams it over BLE. The device decodes mu-law to 16-bit
PCM and writes it to the AW88298 amplifier over I2S. The amplifier needs both
its boost rail (SY7088, enabled through the AW9523 expander) and its 1.8V
digital rail (AXP2101 ALDO1) powered during cold-boot; the I2S link uses BCLK
on GPIO34, word select on GPIO33, and data out on GPIO13 with no master clock.
Output volume is set by the macOS-side gain.

## Hardware

[M5Stack StackChan AI Desktop Robot (Switch Science 11129)](https://www.switch-science.com/products/11129):

- SoC: ESP32-S3 dual-core LX7 at 240MHz, 16MB Flash, 8MB Quad PSRAM
- LCD: 2.0" IPS 320x240 (ILI9342)
- LEDs: 12 WS2812 RGB
- PMIC: AXP2101
- IO expanders: AW9523 and PY32
- Audio: AW88298 Class-D amplifier, 1W speaker
- BLE 5.0 LE (BTstack vendored ESP32 port)

## Development environment

macOS only. The Rakefile assumes macOS paths and the macOS
[`serialport`](https://github.com/larskanis/ruby-serialport) gem. It needs
Xcode with the Swift toolchain (for the `rb-corebluetooth-mac` native
extension), esp-idf v5.4 at `~/esp/esp-idf`, Ruby 4.0+, and Bundler. Building
and controlling the device requires sibling clones of the driver gems,
`R2P2-ESP32`, `rb-corebluetooth-mac`, and `swift_gem` under the same parent
directory.

## Related repositories

### [R2P2-ESP32 fork](https://github.com/bash0C7/R2P2-ESP32)

Adds on top of upstream:

- `sdkconfigs/cores3`: CoreS3 SoC overlay (Quad PSRAM 8MB, 16MB Flash,
  USB-Serial-JTAG console).
- `sdkconfigs/bt_btstack`: BLE enablement with the ROM coex hook disabled, which
  avoids a `LoadProhibited` panic in `coex_schm_lock` on BLE-only builds with
  IDF v5.4 and ESP32-S3.
- `build_config/xtensa-esp-picoruby.rb` (on the `stackchan-integration` branch):
  wires the standalone driver gems and `picoruby-ble` / `picoruby-ble-uart`.
- Points its `components/picoruby-esp32/picoruby` submodule at the picoruby fork
  below.

### [picoruby fork](https://github.com/bash0C7/picoruby)

BLE fixes scoped to `mrbgems/picoruby-ble/`, on the `feature/ble-bringup`
branch. Makes the build host-aware so ESP32 and host can opt out of the Pico W
CYW43 path, and adds an ESP32 port that marshals Ruby-thread BLE calls onto
BTstack's run-loop thread (BTstack is not thread-safe), runs `BLE_init` inside
the BTstack setup callback, and dispatches runtime calls with semaphore
synchronization.

### [rb-corebluetooth-mac](https://github.com/bash0C7/rb-corebluetooth-mac)

A macOS CoreBluetooth binding for Ruby, used by `pc/stackchan` as the
BLE transport.

## License

MIT, see [LICENSE](./LICENSE).

## See also

- [Stack-chan official repository](https://github.com/stack-chan/stack-chan)
- [PicoRuby](https://github.com/picoruby/picoruby)
- [R2P2-ESP32](https://github.com/picoruby/R2P2-ESP32)
