# stackchan-picoruby

> **Status: Work in Progress** — APIs, protocols, and build flow may change without notice.

[Stack-chan](https://github.com/stack-chan/stack-chan) is a super-kawaii robot for the M5Stack platform, created by Shinya Ishikawa and the Stack-chan community.

This repository is a personal port of Stack-chan to [PicoRuby](https://github.com/picoruby/picoruby), running on [R2P2-ESP32](https://github.com/picoruby/R2P2-ESP32) on the [M5Stack StackChan AI Desktop Robot (CoreS3)](https://www.switch-science.com/products/11129).

The hardware layer (LCD, RGB LEDs, IO expanders, BLE peripheral) is reimplemented as out-of-tree PicoRuby `mrbgems`. Higher-level avatar logic is orchestrated from a macOS-side Ruby client over Nordic UART Service (BLE NUS).

## Acknowledgement

Massive thanks to:

- The original [Stack-chan](https://github.com/stack-chan/stack-chan) project by Shinya Ishikawa and the Stack-chan community — the hardware design, the cute face, the entire concept. The official C++ firmware (referenced read-only as `../StackChan` in this monorepo) was indispensable for pin assignments and cold-boot sequences.
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

## Feature matrix vs original

| Subsystem | Original (official) | This repo (PicoRuby) | Notes |
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
| Microphone / Speaker / TTS | ✓ | ✗ | Delegated to macOS side (future) |
| Camera (GC0308) | ✓ | ✗ | Out of scope |
| NFC | ✓ | ✗ | Out of scope |
| Voice synthesis / LLM | community | (planned, macOS-side) | Future macOS-side orchestrator |

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

- M5Stack StackChan AI Desktop Robot ([Switch Science 11129](https://www.switch-science.com/products/11129)) — see Target hardware above
- macOS 26+
- [esp-idf](https://docs.espressif.com/projects/esp-idf/en/v5.4/esp32s3/get-started/index.html) **v5.4**, installed at `~/esp/esp-idf` (the Rakefile sources `~/esp/esp-idf/export.sh`)
- Ruby 4.0+ (rbenv recommended)
- Bundler

### Repository layout — 4 sibling clones required

This monorepo by itself is not enough to build / run / control the device. You need **four** independent sibling clones under the same parent directory. There are no git submodules at this repo's level; R2P2-ESP32's internal `components/picoruby-esp32/picoruby` submodule is fetched in step 1 below via `git clone --recursive`.

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

Two files contain absolute paths hard-coded to the original author's `~/dev/src/github.com/bash0C7/` layout. Edit them to point at **your** clone locations before the first build:

- `R2P2-ESP32/components/picoruby-esp32/build_config/xtensa-esp-picoruby.rb` — 4 `conf.gem gemdir:` lines pointing at this repo's `mrbgems/{picoruby-ili9342, picoruby-py32-io-expander, picoruby-stackchan-led, picoruby-stackchan-protocol}`
- `stackchan-picoruby/pc/stackchan-ble-client/Gemfile` — 2 `gem ... path:` lines (`rb-corebluetooth-mac` and `swift_gem`)

(A future patch may make these relative; for now, edit by hand.)

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

The tables below cover behaviors you will likely encounter while developing on this codebase, along with the recommended response.

### Hardware bring-up

| Topic | Behavior | Recommended response |
|---|---|---|
| CoreS3 cold-boot | LCD and the WS2812 ring need the I2C devices programmed in order: AXP2101 → AW9523 → ILI9342 → PY32 → WS2812 (SDA=GPIO 12, SCL=GPIO 11). | Follow the cold-boot block at the top of `mrbgems/picoruby-stackchan-protocol/examples/application.rb`. |
| BLE start after cold-boot | The synchronous I2C/SPI bring-up (notably the LCD pixel push) keeps BTstack's FreeRTOS task from running, so the first `gap_advertisements_enable(1)` emits nothing. | Insert `sleep_ms 3000` between cold-boot and `BLE.new`. |

### Communication

| Topic | Behavior | Recommended response |
|---|---|---|
| Host ↔ device serial | CoreS3 exposes ESP32-S3 native USB Serial JTAG. Baud rate is cosmetic (115200 is fine for log readability); the device gates TX on DTR. | `lib/deploy/picomodem.rb` opens the port via the `serialport` gem and asserts `serial.dtr = 1`. Reuse it. |
| Mac CoreBluetooth scan | Long device-name suffixes are truncated in scan results. | Keep the advertised name short and stable; match with `--name-prefix` rather than per-board discriminators. |
| Mac CoreBluetooth GATT cache | Services are cached per device identifier and can surface a stale `0 services` view. | Toggle macOS Bluetooth OFF → ON to restart `blued`. For an external sanity check, scan from a second device such as iPhone with nRF Connect. |

### Tooling

| Topic | Behavior | Recommended response |
|---|---|---|
| `idf.py monitor` | Requires a real TTY; produces no output when invoked without one. | Use `bin/capture-with-pty SECONDS LOG_FILE CMD...` for bounded captures (Expect-based, auto-`Ctrl-]` after the timeout), or attach from a real terminal. |
| `mrblib/**/*.rb` reaching the device | `idf.py build` reuses the cached `libmruby.a`, so Ruby-level additions (e.g. a new `Face::*` class) can land on the device only after the cache is rebuilt. | The Rakefile's `clear_libmruby_cache` prerequisite drops `libmruby.a` before every `build_flash`; no manual action needed. |

### Rakefile: a decoration over R2P2-ESP32's

This repo's `Rakefile` wraps R2P2-ESP32's own `rake` tasks (decorator-style) rather than reimplementing the build pipeline. Every `r2p2:*` task ultimately shells into `bash -c '. $IDF_EXPORT && cd $R2P2_ROOT && rake <subtask>'` via the `in_r2p2` helper, so the upstream build flow stays authoritative.

| Decoration | What it adds |
|---|---|
| `espport` auto-detection | Scans `/dev/cu.usbmodem*` and picks one. `ESPPORT=...` env overrides. |
| `ensure_sdkconfig_fresh` | If any `SDKCONFIG_DEFAULTS` fragment is newer than the existing `sdkconfig`, removes `sdkconfig` so the next `idf.py build` regenerates it from fragments. |
| `r2p2:clear_libmruby_cache` (prerequisite of `r2p2:build_flash`) | Drops `libmruby.a` so the next build recompiles all gems from scratch. Adds ~1–2 minutes per build in exchange for guaranteeing `mrblib/**/*.rb` changes reach the device. |
| `r2p2:upload_mrb` (mrbc-style fast path) | Compiles a `.rb` file to `.mrb` on the host with `picorbc`, then ships it over USB-CDC into `/home/app.mrb` via `Deploy::Picomodem.upload` (`lib/deploy/picomodem.rb`). Autostart loads the bytecode directly on next reset. Use this when only the app script changes; a full `build_flash` is reserved for gem (`mrbgems/`) changes. |
| `r2p2:wipe_storage` | Runs `esptool erase_region 0x210000 0x100000` to zero the storage partition (where `/home/*` lives). Use when an autostart app needs to be cleared. |
| `r2p2:ble_control_smoke` | Composite E2E task: `upload_mrb` + `reset` + `autostart_wait` + `pc/stackchan-ble-client`'s CLI inside a `Bundler.with_unbundled_env` subshell. Returns the CLI's exit code so failures surface as rake failures. |

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

## Related repositories

### [R2P2-ESP32 fork](https://github.com/bash0C7/R2P2-ESP32) (of `picoruby/R2P2-ESP32`)

Changes added on top of upstream for this project:

- `sdkconfigs/cores3` — CoreS3 SoC overlay: **Quad** PSRAM 8MB, 16MB Flash, USB-Serial-JTAG console
- `sdkconfigs/bt_btstack` — BLE enablement: BTstack vendored, ROM coex hook disabled (`CONFIG_SW_COEXIST_ENABLE=n` — required to avoid `LoadProhibited` panic in `coex_schm_lock` on BLE-only builds with IDF v5.4 + ESP32-S3)
- `components/picoruby-esp32/build_config/xtensa-esp-picoruby.rb` — wire this repo's mrbgems (`picoruby-ili9342`, `picoruby-py32-io-expander`, `picoruby-stackchan-led`, `picoruby-stackchan-protocol`) and the vendored `picoruby-ble` / `picoruby-ble-uart` via absolute `gemdir`
- Submodule `components/picoruby-esp32/picoruby` repointed (in `.gitmodules`) to `https://github.com/bash0C7/picoruby.git` (the fork documented below) and pinned to a commit on its `feature/ble-bringup` branch — this is how R2P2-ESP32 picks up the BLE port fixes

### [picoruby fork](https://github.com/bash0C7/picoruby) (of `picoruby/picoruby`)

The project-local BLE fixes live on the **`feature/ble-bringup`** branch (not the default branch `master`). [bash0C7/R2P2-ESP32](https://github.com/bash0C7/R2P2-ESP32) pins this fork via its `components/picoruby-esp32/picoruby` submodule (`.gitmodules` → `url = https://github.com/bash0C7/picoruby.git`) at a commit on that branch — currently [`d4909f2a`](https://github.com/bash0C7/picoruby/commit/d4909f2a) "feat(picoruby-ble): make build host-aware so ESP32 and host can opt out of CYW43". Browse the branch to read the full series.

Project-local additions are **scoped entirely to `mrbgems/picoruby-ble/`** (no other mrbgem / no other porting is touched). 3 commits, ~644 lines:

- `mrbgems/picoruby-ble/mrbgem.rake` + `mrblib/ble.rb` — make the build host-aware so ESP32 and host can opt out of the Pico W CYW43 path (upstream's only port was Pico W)
- `mrbgems/picoruby-ble/ports/esp32/` (new directory, 6 files):
  - `btstack_owner.c/.h` — `picoruby_btstack_ensure_started(setup_cb, ctx)` and `picoruby_btstack_run_sync(cb, ctx)` so Ruby-thread BLE calls can be marshalled onto BTstack's FreeRTOS run-loop thread (BTstack is not thread-safe; this avoids `LoadProhibited` panics in `hci_*` / `gap_*` from the wrong thread)
  - `ble_peripheral.c` / `ble_central.c` / `ble_common.h` — peripheral and central wrappers
  - `ble.c` — `BLE_init` owns `profile_data`; `l2cap_init` / `sm_init` / `att_server_init` / `hci_add_event_handler` run inside the BTstack setup callback (before `run_loop_execute`); runtime calls (`hci_power_control`, `gap_advertisements_enable`, etc.) dispatch via `btstack_run_loop_execute_on_main_thread` with semaphore-synchronous wait (same-thread invocation short-circuits to direct call to avoid deadlock); Security Manager / RPA hardening + att_db debug aids

### [rb-corebluetooth-mac](https://github.com/bash0C7/rb-corebluetooth-mac)

Original gem (not a fork). macOS CoreBluetooth Ruby binding, used by `pc/stackchan-ble-client` as the BLE transport (path-loaded in its `Gemfile`).

## License

MIT — see [LICENSE](./LICENSE).

## See also

- [Stack-chan official repository](https://github.com/stack-chan/stack-chan)
- [PicoRuby](https://github.com/picoruby/picoruby)
- [R2P2-ESP32](https://github.com/picoruby/R2P2-ESP32)
