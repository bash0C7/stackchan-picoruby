# stackchan-picoruby

> **Status: Work in Progress** — APIs, protocols, and build flow may change without notice.

[Stack-chan](https://github.com/stack-chan/stack-chan) is a super-kawaii robot for the M5Stack platform, created by Shinya Ishikawa and the Stack-chan community.

This repository is a personal port of Stack-chan to [PicoRuby](https://github.com/picoruby/picoruby), running on [R2P2-ESP32](https://github.com/picoruby/R2P2-ESP32) on the [M5Stack StackChan AI Desktop Robot (CoreS3)](https://www.switch-science.com/products/11129).

The hardware layer (LCD, RGB LEDs, IO expanders, BLE peripheral) is reimplemented as out-of-tree PicoRuby `mrbgems`. A macOS-side Ruby client orchestrates higher-level avatar logic over Nordic UART Service (BLE NUS).

## Acknowledgement

Massive thanks to:

- The original [Stack-chan](https://github.com/stack-chan/stack-chan) project by Shinya Ishikawa and the Stack-chan community — the hardware design, the cute face, the entire concept. The official C++ firmware (referenced read-only as `../StackChan` in this monorepo) provided the pin assignments and cold-boot sequences.
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
- **macOS side**: orchestrator. Sends control frames (face × LED color × animation mode × side selector), receives ACK (`.`) or ERR (`?`) replies.
- **Frame protocol**: K=V semicolon-delimited frames with single-byte ACK or ERR replies. See `mrbgems/picoruby-stackchan-protocol/` and `pc/stackchan-ble-client/` for implementation.

## Project structure

| Layer | Location | Build cycle |
|---|---|---|
| Drivers | `mrbgems/picoruby-*` + R2P2-ESP32 ports | `stackchan-device-build-flash` (~5-10 min) |
| Protocol framework (FrameParser) | `mrbgems/picoruby-stackchan-protocol` | `stackchan-device-build-flash` |
| Application (Face DSL, Dispatcher, BLE peripheral) | `mrbgems/picoruby-stackchan-protocol/examples/application.rb` | `stackchan-device-deploy-app` (~20 s) |
| Host tests | `test/`, `lib/ruby_class_extract.rb` | `bundle exec rake test` |

The single `application.rb` is the autostart payload; on-device requires
only resolve under PicoRuby. Host tests load the file via prism AST
extraction (`lib/ruby_class_extract.rb`).

## Dev iteration

```
edit application.rb -> rake test            # host tests (~3 s)
                    -> /stackchan-device-iterate  # device deploy + boot verify (~50 s)
```

## Deploy skills

| Skill | Slash alias | Purpose |
|---|---|---|
| stackchan-device-build-flash | yes | rebuild firmware + flash |
| stackchan-device-setup | yes | host picoruby + target setup |
| stackchan-device-reset | yes | RTS pulse + 15 s settle |
| stackchan-device-wipe | yes | erase /home storage partition |
| stackchan-device-capture-boot | yes | log device serial to /tmp/boot.log |
| stackchan-device-face-verify | yes | host golden SHA + device ACK |
| stackchan-device-deploy-app | yes | upload .mrb + reset |
| stackchan-device-cold-recovery | yes | wipe + redeploy + reset |
| stackchan-device-full-rebuild | yes | build_flash + cold-recovery |
| stackchan-device-boot-verify | yes | reset + capture + auto-analyze |
| stackchan-device-iterate | yes | upload + reset + capture + analyze |

Internal (no slash alias): upload-app, upload-lib, crash-analyze, ble-smoke
— driven by claude during chain flows.

## Recovery hierarchy

If a deploy goes wrong, escalate in this order:

1. `/stackchan-device-cold-recovery` — wipe + retry, ~30 s
2. `/stackchan-device-full-rebuild` — rebuild firmware first, ~5-10 min
3. Human help — USB replug / monitor + `rm /home/app.mrb` / download mode

Do not iterate on step 1 more than twice; escalate.

## Host tests

```
bundle install
bundle exec rake test
```

Tests cover Face geometry, Dispatcher routing, golden-SHA regression, and
the RubyClassExtract library itself. They DO NOT exercise on-device
behavior — that is verified via `/stackchan-device-iterate` and
`/stackchan-device-face-verify`.

## Feature matrix vs original

| Subsystem | Original (official) | This repo (PicoRuby) | Notes |
|---|---|---|---|
| Core 4 faces (Neutral / Smile / Joy / Surprised) | ✓ | ✓ | Custom geometry, photo-derived ratios |
| Extended emotions (Angry / Sad / Closed) | ✓ | ✓ | `Face::Sad` / `Face::Angry` / `Face::Closed` (idle indicator) |
| Eye-blink liveness animation | partial | ✓ | Eye-only redraw, no full-screen flicker |
| RGB LED ring (12 px) | ✓ | ✓ | `solid` / `blink` / `breathing` / `off`, per-side (`L`/`R`/`both`) |
| BLE control (Nordic UART Service) | (community) | ✓ | NUS RX/TX + ACK queue + heartbeat tick |
| WiFi + HTTP / MQTT / WebSocket | ✓ | (planned) | `picoruby-net-*` gems available, awaiting wiring |
| Servo control (yaw + pitch) | ✓ | ✓ | Normalized `YL/YR/PU` protocol + operator BLE calibrate CLI |
| IMU (BMI270 + BMM150) | ✓ | ✗ | (planned) |
| 3-zone touch (head Si12T) | ✓ | ✗ | (planned) |
| Microphone / Speaker / TTS | ✓ | ✗ | Delegates to macOS side (planned) |
| Camera (GC0308) | ✓ | ✗ | (deferred) |
| NFC | ✓ | ✗ | (deferred) |
| Voice synthesis / LLM | community | (planned) | macOS-side orchestrator integration |

## Target hardware

[M5Stack StackChan AI Desktop Robot (Switch Science 11129)](https://www.switch-science.com/products/11129):

- SoC: **ESP32-S3** dual-core LX7 @ 240MHz, 16MB Flash, 8MB Quad PSRAM
- LCD: 2.0" IPS 320×240 (ILI9342)
- LEDs: 12× WS2812 RGB
- PMIC: AXP2101
- IO Expanders: AW9523 + PY32
- BLE 5.0 LE (BTstack vendored ESP32 port)

## Development environment

**macOS only.** The Rakefile assumes macOS paths (`~/.espressif/python_env/...`, `/dev/cu.usbmodem*`) and uses the macOS-flavored [`serialport`](https://github.com/larskanis/ruby-serialport) gem. Porting to Linux or Windows requires changes in `Rakefile` and `lib/deploy/picomodem.rb`.

### Prerequisites

- M5Stack StackChan AI Desktop Robot ([Switch Science 11129](https://www.switch-science.com/products/11129)) — see Target hardware above
- macOS 26+
- **Xcode** with the Swift toolchain — `swift_gem` builds a Swift Package Manager-backed native extension during `bundle install`, and `rb-corebluetooth-mac` depends on it
- [esp-idf](https://docs.espressif.com/projects/esp-idf/en/v5.4/esp32s3/get-started/index.html) **v5.4**, installed at `~/esp/esp-idf` (the Rakefile sources `~/esp/esp-idf/export.sh`)
- Ruby 4.0+ (rbenv recommended)
- Bundler

### Repository layout — 4 sibling clones required

Building and controlling the device requires **four** independent sibling clones under the same parent directory. There are no git submodules at this repo's level; R2P2-ESP32 manages its internal `components/picoruby-esp32/picoruby` submodule, fetched in step 1 below via `git clone --recursive`.

```
your/parent/dir/
├── stackchan-picoruby/       (this repo)
├── R2P2-ESP32/               (fork; contains picoruby fork as an internal submodule)
├── rb-corebluetooth-mac/     (path-loaded by pc/stackchan-ble-client)
└── swift_gem/                (path-loaded by pc/stackchan-ble-client; also a runtime dep of rb-corebluetooth-mac)
```

### First-time setup

#### 1. Clone all four repos

```bash
cd your/parent/dir
git clone https://github.com/bash0C7/stackchan-picoruby
git clone --recursive https://github.com/bash0C7/R2P2-ESP32     # --recursive pulls the pinned bash0C7/picoruby submodule
git clone https://github.com/bash0C7/rb-corebluetooth-mac
git clone https://github.com/bash0C7/swift_gem
```

If you forgot `--recursive` on R2P2-ESP32: `cd R2P2-ESP32 && git submodule update --init --recursive`.

#### 2. Edit absolute paths to your layout

Two files assume the original author's `~/dev/src/github.com/bash0C7/` layout. Edit them to point at **your** clone locations before the first build:

- `R2P2-ESP32/components/picoruby-esp32/build_config/xtensa-esp-picoruby.rb` — Update 4 `conf.gem gemdir:` lines to point at this repo's `mrbgems/{picoruby-ili9342, picoruby-py32-io-expander, picoruby-stackchan-led, picoruby-stackchan-protocol}`
- `stackchan-picoruby/pc/stackchan-ble-client/Gemfile` — Update 2 `gem ... path:` lines for `rb-corebluetooth-mac` and `swift_gem`

#### 3. Bundle install (2 locations)

```bash
cd stackchan-picoruby
bundle install                                              # root: Rakefile + picomodem uploader
( cd pc/stackchan-ble-client && bundle install )            # BLE client side
```

#### 4. Host picoruby setup + first device flash

```bash
bundle exec rake r2p2:setup        # ~10-20 min, builds host picoruby + sets ESP32-S3 target
bundle exec rake r2p2:build_flash  # ~5-10 min, idf.py build + flash
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

The tables below collect the behaviors you are most likely to encounter while working on this codebase, together with the recommended response for each.

### Hardware bring-up

| Topic | Behavior | Recommended response |
|---|---|---|
| CoreS3 cold-boot | The LCD and the WS2812 ring come up only after the I2C bus programs the devices in this order: AXP2101 → AW9523 → ILI9342 → PY32 → WS2812 (SDA=GPIO 12, SCL=GPIO 11). | Follow the cold-boot block at the top of `mrbgems/picoruby-stackchan-protocol/examples/application.rb`. |
| Starting BLE after cold-boot | The synchronous I2C/SPI work during cold-boot — in particular the LCD pixel push — keeps BTstack's FreeRTOS task from starting. As a result, the first `gap_advertisements_enable(1)` runs without emitting any radio packets. | Insert `sleep_ms 3000` between the cold-boot block and `BLE.new`. |

### Communication

| Topic | Behavior | Recommended response |
|---|---|---|
| Host ↔ device serial | CoreS3 communicates with the host through the ESP32-S3 native USB Serial JTAG controller. Baud rate is informational only (115200 keeps logs readable); the device accepts TX only after DTR is asserted. | `lib/deploy/picomodem.rb` opens the port via the `serialport` gem and sets `serial.dtr = 1`. Reuse it. |
| Mac CoreBluetooth scan | macOS shortens long advertised device names in scan results. | Use a short and stable advertised name, and match it with `--name-prefix` rather than per-board discriminators. |
| Mac CoreBluetooth GATT cache | macOS caches GATT services per device identifier and sometimes returns a stale "0 services" view. | Toggle macOS Bluetooth OFF → ON to restart `blued`. For an independent sanity check, scan from another device such as an iPhone running nRF Connect. |

### Tooling

| Topic | Behavior | Recommended response |
|---|---|---|
| `idf.py monitor` | Needs a real terminal. When invoked without one it prints nothing. | Use `bin/capture-with-pty SECONDS LOG_FILE CMD...` for bounded captures (Expect-based, sends `Ctrl-]` automatically after the timeout), or attach from a real terminal. |
| Getting `mrblib/**/*.rb` changes onto the device | `idf.py build` keeps the cached `libmruby.a` and skips recompiling gems. Newly added Ruby code — for example a new `Face::*` class — reaches the device only after that cache is cleared. | The Rakefile's `clear_libmruby_cache` prerequisite removes `libmruby.a` before every `build_flash`, so no manual action is needed. |

### Rakefile: a decoration over R2P2-ESP32's

This repo's `Rakefile` wraps R2P2-ESP32's `rake` tasks (via `in_r2p2` helper) to keep the upstream build flow authoritative. Every `r2p2:*` task runs `bash -c '. $IDF_EXPORT && cd $R2P2_ROOT && rake <subtask>'`, avoiding duplication of the build pipeline.

| Decoration | What it adds |
|---|---|
| `espport` auto-detection | Scans `/dev/cu.usbmodem*` and picks one. Override with `ESPPORT=...`. |
| `ensure_sdkconfig_fresh` | If any `SDKCONFIG_DEFAULTS` fragment is newer than the current `sdkconfig`, removes `sdkconfig` so the next `idf.py build` regenerates it from the fragments. |
| `r2p2:clear_libmruby_cache` (prerequisite of `r2p2:build_flash`) | Removes `libmruby.a` so the next build recompiles all gems from scratch. Adds about 1–2 minutes per build and guarantees that `mrblib/**/*.rb` changes reach the device. |
| `r2p2:upload_mrb` (fast-path compilation) | Compiles a `.rb` file to `.mrb` on the host with `picorbc`, then uploads it over USB-CDC to `/home/app.mrb` via `Deploy::Picomodem.upload` (`lib/deploy/picomodem.rb`). Autostart loads the bytecode on the next reset. Use this for app-script changes only; reserve `build_flash` for gem changes under `mrbgems/`. |
| `r2p2:wipe_storage` | Runs `esptool erase_region 0x210000 0x100000` to zero the storage partition (where `/home/*` lives). Use this to clear an autostart app from the device. |
| `r2p2:ble_control_smoke` | Composite E2E task that uploads the app, resets the device, waits for autostart, then runs `pc/stackchan-ble-client`'s CLI inside a `Bundler.with_unbundled_env` subshell. Returns the CLI's exit code so test failures appear as rake failures. |

## Repository layout

```
mrbgems/                                  out-of-tree PicoRuby gems
├── picoruby-ili9342/                     LCD driver
├── picoruby-py32-io-expander/            PY32 I/O expander (LEDs, VM_EN)
├── picoruby-stackchan-led/               WS2812 12-px ring animator
└── picoruby-stackchan-protocol/          face render + frame protocol + BLE app

pc/                                       macOS-side Ruby clients
├── stackchan-protocol/                   frame codec / CLI for serial control
├── stackchan-ble-client/                 BLE NUS client + control CLI
└── stackchan-notifier/                   Claude Code hooks → BLE bridge (daemon + CLI)

lib/deploy/                               host-side picomodem uploader (serialport gem)
docs/                                     specs, plans, handoffs
Rakefile                                  workflow wrappers (r2p2:*, build_flash, ble_control_smoke, etc.)
```

## Related repositories

### [R2P2-ESP32 fork](https://github.com/bash0C7/R2P2-ESP32) (of `picoruby/R2P2-ESP32`)

Adds the following on top of upstream:

- `sdkconfigs/cores3` — CoreS3 SoC overlay: **Quad** PSRAM 8MB, 16MB Flash, USB-Serial-JTAG console
- `sdkconfigs/bt_btstack` — BLE enablement: BTstack vendored, ROM coex hook disabled (`CONFIG_SW_COEXIST_ENABLE=n`) to avoid `LoadProhibited` panics in `coex_schm_lock` on BLE-only builds with IDF v5.4 + ESP32-S3
- `components/picoruby-esp32/build_config/xtensa-esp-picoruby.rb` — Wires this repo's mrbgems (`picoruby-ili9342`, `picoruby-py32-io-expander`, `picoruby-stackchan-led`, `picoruby-stackchan-protocol`) and the vendored `picoruby-ble` / `picoruby-ble-uart` via absolute `gemdir`
- Submodule `components/picoruby-esp32/picoruby` points to `https://github.com/bash0C7/picoruby.git` (the fork documented below) pinned to the `feature/ble-bringup` branch to integrate BLE port fixes

### [picoruby fork](https://github.com/bash0C7/picoruby) (of `picoruby/picoruby`)

Project-local BLE fixes live on the **`feature/ble-bringup`** branch (not the default `master`). [bash0C7/R2P2-ESP32](https://github.com/bash0C7/R2P2-ESP32) pins this fork at a commit on that branch via its `components/picoruby-esp32/picoruby` submodule — currently [`d4909f2a`](https://github.com/bash0C7/picoruby/commit/d4909f2a) "feat(picoruby-ble): make build host-aware so ESP32 and host can opt out of CYW43". Browse the branch for the full commit series.

Changes are **scoped to `mrbgems/picoruby-ble/` only** (no other mrbgem or porting affected). 3 commits, ~644 lines:

- `mrbgems/picoruby-ble/mrbgem.rake` + `mrblib/ble.rb` — Make the build host-aware so ESP32 and host can opt out of the Pico W CYW43 path (upstream only supported Pico W)
- `mrbgems/picoruby-ble/ports/esp32/` (6 new files):
  - `btstack_owner.c/.h` — Exports `picoruby_btstack_ensure_started(setup_cb, ctx)` and `picoruby_btstack_run_sync(cb, ctx)` to marshal Ruby-thread BLE calls onto BTstack's FreeRTOS run-loop thread (BTstack is not thread-safe; this avoids `LoadProhibited` panics in `hci_*` / `gap_*` from the wrong thread)
  - `ble_peripheral.c` / `ble_central.c` / `ble_common.h` — Peripheral and central wrappers
  - `ble.c` — Runs `BLE_init` as owner of `profile_data`; executes `l2cap_init` / `sm_init` / `att_server_init` / `hci_add_event_handler` inside the BTstack setup callback (before `run_loop_execute`); dispatches runtime calls (`hci_power_control`, `gap_advertisements_enable`, etc.) via `btstack_run_loop_execute_on_main_thread` with semaphore-synchronous wait (same-thread invocation short-circuits to direct call to avoid deadlock). Includes Security Manager / RPA hardening and att_db debug aids.

### [rb-corebluetooth-mac](https://github.com/bash0C7/rb-corebluetooth-mac)

Original gem (not a fork). Provides macOS CoreBluetooth bindings for Ruby. Used by `pc/stackchan-ble-client` as the BLE transport (path-loaded in its `Gemfile`).

## License

MIT — see [LICENSE](./LICENSE).

## See also

- [Stack-chan official repository](https://github.com/stack-chan/stack-chan)
- [PicoRuby](https://github.com/picoruby/picoruby)
- [R2P2-ESP32](https://github.com/picoruby/R2P2-ESP32)
