# stackchan-picoruby

> **Status: Work in Progress** — APIs, protocols, and build flow may change without notice.

[Stack-chan](https://github.com/stack-chan/stack-chan) is a super-kawaii robot for the M5Stack platform, created by Shinya Ishikawa and the Stack-chan community.

This repository is a personal port of Stack-chan to [PicoRuby](https://github.com/picoruby/picoruby), running on [R2P2-ESP32](https://github.com/picoruby/R2P2-ESP32) on the [M5Stack StackChan AI Desktop Robot (CoreS3)](https://www.switch-science.com/products/11129).

The hardware layer (LCD, RGB LEDs, IO expanders, BLE peripheral) is reimplemented as out-of-tree PicoRuby `mrbgems`. Higher-level avatar logic is orchestrated from a macOS-side Ruby client over Nordic UART Service (BLE NUS).

## Acknowledgement

Massive thanks to:

- The upstream [Stack-chan](https://github.com/stack-chan/stack-chan) project by Shinya Ishikawa and the Stack-chan community — the hardware design, the cute face, the entire concept. The official C++ firmware (referenced read-only as `../StackChan` in this monorepo) was indispensable for pin assignments and cold-boot sequences.
- [PicoRuby](https://github.com/picoruby/picoruby) by [@hasumikin](https://github.com/hasumikin) and contributors.
- [R2P2-ESP32](https://github.com/picoruby/R2P2-ESP32) for the ESP32 port that made any of this possible.

## Architecture

```
+-----------+   BLE NUS (frame protocol + ACK queue)   +---------------------+
|  macOS    | <--------------------------------------> |  CoreS3 / R2P2      |
|  (Ruby    |                                          |  PicoRuby + mrbgems |
|  client)  |                                          |  LCD / LED / BLE    |
+-----------+                                          +---------------------+
```

- **CoreS3 side**: I/O endpoint. Renders faces, drives the 12× WS2812 RGB ring (per-side, animated), advertises NUS, listens for control frames.
- **macOS side**: orchestrator. Sends control frames (face × LED color × animation mode × side selector), receives ACK / ERR bytes.
- **Frame protocol**: K=V semicolon-delimited frames, single-byte ACK (`.`) or ERR (`?`) reply. Implementation in `mrbgems/picoruby-stackchan-protocol/` and `pc/stackchan-ble-client/`.

## Feature matrix vs upstream

| Subsystem | Upstream (official) | This repo (PicoRuby) | Notes |
|---|---|---|---|
| Core 4 faces (Neutral / Smile / Joy / Surprised) | ✓ | ✓ | Custom geometry, photo-derived ratios |
| Extended emotions (Angry / Sad / etc.) | ✓ | ✗ | Out of scope — easy to add as new `Face::*` |
| Eye-blink liveness animation | partial | ✓ | Eye-only redraw, no full-screen flicker |
| RGB LED ring (12 px) | ✓ | ✓ | `solid` / `blink` / `breathing` / `off`, per-side (`L`/`R`/`both`) |
| BLE control (Nordic UART Service) | (community) | ✓ | NUS RX/TX + ACK queue + heartbeat tick |
| WiFi + HTTP / MQTT / WebSocket | ✓ | (planned) | `picoruby-net-*` gems available, not wired up yet |
| Servo control (neck pan + tilt) | ✓ | ✗ | Planned (`picoruby-scservo`) |
| IMU (BMI270 + BMM150) | ✓ | ✗ | Planned (`picoruby-bmi270`) |
| 3-zone touch (head Si12T) | ✓ | ✗ | Not started |
| Microphone / Speaker / TTS | ✓ | ✗ | Delegated to macOS side (`rb-foundation-model-mac`) |
| Camera (GC0308) | ✓ | ✗ | Out of scope |
| NFC | ✓ | ✗ | Out of scope |
| Voice synthesis / LLM | community | (planned, macOS-side) | Via `rb-foundation-model-mac` orchestrator |

## Target hardware

[M5Stack StackChan AI Desktop Robot (Switch Science 11129)](https://www.switch-science.com/products/11129):

- SoC: **ESP32-S3** dual-core LX7 @ 240MHz, 16MB Flash, 8MB Quad PSRAM
- LCD: 2.0" IPS 320×240 (ILI9342)
- LEDs: 12× WS2812 RGB
- PMIC: AXP2101
- IO Expanders: AW9523 + PY32
- BLE 5.0 LE (BTstack vendored ESP32 port)

## Development environment

**macOS only.** The Rakefile hard-codes macOS paths (`~/.espressif/python_env/...`, `/dev/cu.usbmodem*`) and uses the macOS-flavored [`serialport`](https://github.com/larskanis/ruby-serialport) gem. Linux / Windows would need rewrites in `Rakefile` and `lib/deploy/picomodem.rb`.

### Prerequisites

- macOS 26+
- [esp-idf](https://docs.espressif.com/projects/esp-idf/en/v5.4/esp32s3/get-started/index.html) **v5.4**, installed at `~/esp/esp-idf`
- Ruby 4.0+ required (rbenv recommended)
- `bundler`
- [`ghq`](https://github.com/x-motemen/ghq) for repository layout (optional but assumed)

### Repository layout

This monorepo expects an **independent sibling clone** of `R2P2-ESP32` (fork required — sdkconfig fragments and BLE bring-up live there). These are **not** git submodules; the path is baked into `R2P2-ESP32/components/picoruby-esp32/build_config/xtensa-esp-picoruby.rb` (absolute) and this repo's Rakefile (relative). Clone them separately:

```
~/dev/src/github.com/bash0C7/
├── stackchan-picoruby/    (this repo)
└── R2P2-ESP32/            (https://github.com/bash0C7/R2P2-ESP32, fork — clone separately)
```

### First-time setup

```bash
ghq get github.com/bash0C7/stackchan-picoruby
ghq get github.com/bash0C7/R2P2-ESP32
cd ~/dev/src/github.com/bash0C7/stackchan-picoruby
bundle install
bundle exec rake r2p2:setup       # ~10-20 min, builds host picoruby + sets ESP32-S3 target
```

### Build + flash + smoke

```bash
bundle exec rake r2p2:build_flash       # ~5-10 min; auto-clears libmruby cache on mrblib changes
bundle exec rake r2p2:wipe_storage      # ~7s, clean /home partition
bundle exec rake r2p2:ble_control_smoke COLOR=red MODE=blink FACE=joy SIDE=both
```

Expected smoke output ends with:
```
[smoke] PASS — face=joy LED=red blink (side=both) — visual check please
```

Visual sanity check: joy face on LCD, both sides red blinking, eye-blink animation every ~5 seconds.

### Recovery — when `/home/app.mrb` wedges autostart

```bash
bundle exec rake r2p2:wipe_storage
```

If `wipe_storage` itself stalls (USB-CDC re-enumeration issues), fall back to `bundle exec rake r2p2:build_flash` for a full reflash. If that also fails, USB cable cycle + M5Stack power cycle is the last resort.

## Development notes

### CoreS3 cold-boot is non-trivial

LCD + WS2812 do not work from a cold boot using ESP32 SoC SPI/GPIO init alone. You must walk the I2C bus (SDA=GPIO 12, SCL=GPIO 11) and program AXP2101 → AW9523 → ILI9342 → PY32 → WS2812 in the correct order. See the cold-boot block at the top of `mrbgems/picoruby-stackchan-protocol/examples/application.rb` for the working sequence.

### BLE bring-up gotcha

After cold-boot, you **must** `sleep_ms 3000` before starting BLE. The synchronous I2C/SPI cold-boot block (in particular the LCD pixel push) starves BTstack's FreeRTOS task. Without the yield, `gap_advertisements_enable(1)` is called but never actually emits — the device logs `HCI WORKING — advertising` while iPhone / Mac scanners see nothing. Verified by bisect (2026-05-17).

### USB-CDC: ESP32-S3 native (USB Serial JTAG), DTR-gated

CoreS3 uses the ESP32-S3 native USB Serial JTAG controller, not TinyUSB CDC ACM. The host uploader (`lib/deploy/picomodem.rb`) must set `DTR=1` on serial open, or the device will refuse TX. This is why the project uses the `serialport` gem (DTR control) rather than `uart` (no DTR API).

Baud rate is functionally ignored by USB Serial JTAG — the value is cosmetic. Set to 115200 for human-readability of log output.

### Mac CoreBluetooth quirks

- Device name suffixes are **truncated** by Mac CoreBluetooth scan caching. Do not rely on long discriminators (epoch suffixes etc.) — Mac will only show the base name. Use a fixed `--name-prefix` and tolerate a single board per session.
- GATT cache trap: Mac CoreBluetooth caches GATT services per device identifier and can serve a `0 services` stale view. The only reliable reset is **Bluetooth OFF → ON** (which restarts `blued`). Cross-check with iPhone (e.g. nRF Connect) when the Mac side stalls.

### Rake task discipline

Long-running rake tasks (`r2p2:build_flash`, `r2p2:setup`) take minutes. The `r2p2:build_flash` task auto-clears the libmruby cache (`clear_libmruby_cache` prerequisite) when invoked — this catches the `idf.py build` silent-bytecode-cache trap that previously caused mrblib changes (e.g. new `Face::*` classes) to be dropped at runtime as `NameError`.

`idf.py monitor` cannot run from a TTY-less environment. Use `bin/capture-with-pty SECONDS LOG_FILE CMD...` for bounded captures (Expect-based, auto-`Ctrl-]` after the timeout), or attach manually from a real terminal.

## Repository layout

```
mrbgems/                                  out-of-tree PicoRuby gems
├── picoruby-ili9342/                     LCD driver
├── picoruby-py32-io-expander/            PY32 I/O expander (LEDs, VM_EN)
├── picoruby-stackchan-led/               WS2812 12-px ring animator
└── picoruby-stackchan-protocol/          face render + frame protocol + BLE app

pc/                                       macOS-side Ruby clients
├── stackchan-protocol/                   frame codec / CLI for serial control
└── stackchan-ble-client/                 BLE NUS client + control CLI

lib/deploy/                               host-side picomodem uploader (serialport gem)
docs/                                     specs, plans, handoffs
Rakefile                                  workflow wrappers (r2p2:*, build_flash, ble_control_smoke, etc.)
```

## Related repositories (bash0C7 forks)

- [R2P2-ESP32 (fork)](https://github.com/bash0C7/R2P2-ESP32) — CoreS3 sdkconfig fragments, BLE bring-up, BTstack thread bridging
- [picoruby (fork)](https://github.com/bash0C7/picoruby) — BLE port modifications (BTstack ESP32 port thread safety)
- [rb-foundation-model-mac](https://github.com/bash0C7/rb-foundation-model-mac) — Apple Foundation Model Ruby bindings (macOS-side orchestration)

## License

MIT — see [LICENSE](./LICENSE).

## See also

- [Stack-chan official repository](https://github.com/stack-chan/stack-chan)
- [PicoRuby](https://github.com/picoruby/picoruby)
- [R2P2-ESP32](https://github.com/picoruby/R2P2-ESP32)
