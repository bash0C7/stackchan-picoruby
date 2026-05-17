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

- macOS 26+
- [esp-idf](https://docs.espressif.com/projects/esp-idf/en/v5.4/esp32s3/get-started/index.html) **v5.4**, installed at `~/esp/esp-idf`
- Ruby 4.0+ required (rbenv recommended)
- `bundler`

### Repository layout

This monorepo expects an **independent sibling clone** of `R2P2-ESP32` (fork required — sdkconfig fragments and BLE bring-up live there). These are **not** git submodules; the path is baked into `R2P2-ESP32/components/picoruby-esp32/build_config/xtensa-esp-picoruby.rb` (absolute) and this repo's Rakefile (relative). Clone them under the same parent directory:

```
your/parent/dir/
├── stackchan-picoruby/    (this repo)
└── R2P2-ESP32/            (https://github.com/bash0C7/R2P2-ESP32, fork — clone separately)
```

### First-time setup

```bash
cd your/parent/dir
git clone https://github.com/bash0C7/stackchan-picoruby
git clone https://github.com/bash0C7/R2P2-ESP32
cd stackchan-picoruby
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

### Rakefile: a decoration over R2P2-ESP32's

This repo's `Rakefile` doesn't reimplement the build pipeline — it **wraps** R2P2-ESP32's own `rake` tasks (decorator-style), adding project-specific guards and conveniences. Every `r2p2:*` task ultimately shells into `bash -c '. $IDF_EXPORT && cd $R2P2_ROOT && rake <subtask>'` via the `in_r2p2` helper, so the upstream build flow stays authoritative.

Decorations layered on top of upstream:

- **`espport` auto-detection** — scans `/dev/cu.usbmodem*` and picks one. `ESPPORT=...` env overrides.
- **`ensure_sdkconfig_fresh`** — if any `SDKCONFIG_DEFAULTS` fragment is newer than the existing `sdkconfig`, `rm sdkconfig` so the next `idf.py build` regenerates it from fragments. (`idf.py build` does **not** re-apply `SDKCONFIG_DEFAULTS` to an already-existing `sdkconfig`, so fragment edits are otherwise silently dropped — caught only at runtime as missing config defines.)
- **`r2p2:clear_libmruby_cache` (prerequisite of `r2p2:build_flash`)** — unconditionally `rm`s `libmruby.a` so the next build re-runs picoruby's mruby compile from scratch. Without this, `idf.py build` trusts the cached `libmruby.a` and **silently drops `mrblib/**/*.rb` changes** — e.g. a new `Face::Closed` class added to a gem manifests at runtime on the device as `NameError`, not at compile time. (~1-2 extra minutes per build for correctness.)
- **`r2p2:upload_mrb`** — host-side **mrbc-style flow**: `picorbc` compiles a `.rb` file to `.mrb` bytecode on the host, then `Deploy::Picomodem.upload` (lib/deploy/picomodem.rb) ships it over USB-CDC into the device's `/home/app.mrb`. Autostart on next reset loads the bytecode directly (no on-device compile). This is the iteration-fast path: no rebuild/flash needed when only app logic changes — a full `build_flash` is only needed when gems (`mrbgems/`) themselves change.
- **`r2p2:wipe_storage`** — `esptool erase_region 0x210000 0x100000` zeroes the storage partition (where `/home/*` lives). Use when an autostart app wedges the shell or PicoModem session won't handshake.
- **`r2p2:ble_control_smoke`** — composite E2E task: `upload_mrb` + `reset` + `autostart_wait` + invoke `pc/stackchan-ble-client`'s CLI inside a `Bundler.with_unbundled_env` subshell (so the inner Gemfile resolves correctly). Returns the CLI's exit code, so failures surface as rake failures.

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

## Related repositories

### [R2P2-ESP32 fork](https://github.com/bash0C7/R2P2-ESP32) (of `picoruby/R2P2-ESP32`)

Changes added on top of upstream for this project:

- `sdkconfigs/cores3` — CoreS3 SoC overlay: **Quad** PSRAM 8MB, 16MB Flash, USB-Serial-JTAG console
- `sdkconfigs/bt_btstack` — BLE enablement: BTstack vendored, ROM coex hook disabled (`CONFIG_SW_COEXIST_ENABLE=n` — required to avoid `LoadProhibited` panic in `coex_schm_lock` on BLE-only builds with IDF v5.4 + ESP32-S3)
- `components/picoruby-esp32/build_config/xtensa-esp-picoruby.rb` — wire this repo's mrbgems (`picoruby-ili9342`, `picoruby-py32-io-expander`, `picoruby-stackchan-led`, `picoruby-stackchan-protocol`) and the vendored `picoruby-ble` / `picoruby-ble-uart` via absolute `gemdir`
- Submodule `components/picoruby-esp32/picoruby` repointed (in `.gitmodules`) to `https://github.com/bash0C7/picoruby.git` (the fork documented below) and pinned to a commit on its `feature/ble-bringup` branch — this is how R2P2-ESP32 picks up the BLE port fixes

### [picoruby fork](https://github.com/bash0C7/picoruby) (of `picoruby/picoruby`)

The project-local BLE fixes live on the **`feature/ble-bringup`** branch (not the default branch `master`). [bash0C7/R2P2-ESP32](https://github.com/bash0C7/R2P2-ESP32) pins this fork via its `components/picoruby-esp32/picoruby` submodule (`.gitmodules` → `url = https://github.com/bash0C7/picoruby.git`) at a commit on that branch — currently [`d4909f2a`](https://github.com/bash0C7/picoruby/commit/d4909f2a) "feat(picoruby-ble): make build host-aware so ESP32 and host can opt out of CYW43". Browse the branch to read the full series.

Project-local additions — all in `mrbgems/picoruby-ble/ports/esp32/`:

- `btstack_owner.c` — new `picoruby_btstack_ensure_started(setup_cb, ctx)` and `picoruby_btstack_run_sync(cb, ctx)` APIs so Ruby-thread BLE calls can be marshalled onto BTstack's FreeRTOS run-loop thread (BTstack is not thread-safe; this avoids LoadProhibited panics in `hci_*` / `gap_*` from the wrong thread)
- `BLE_init`'s `l2cap_init` / `sm_init` / `att_server_init` / `hci_add_event_handler` block runs inside the BTstack setup callback (before `run_loop_execute`)
- Runtime calls (`hci_power_control`, `gap_advertisements_enable`, etc.) dispatch via `btstack_run_loop_execute_on_main_thread` with semaphore-synchronous wait; same-thread invocation short-circuits to direct call to avoid deadlock

### [rb-corebluetooth-mac](https://github.com/bash0C7/rb-corebluetooth-mac)

Original gem (not a fork). macOS CoreBluetooth Ruby binding, used by `pc/stackchan-ble-client` as the BLE transport (path-loaded in its `Gemfile`).

## License

MIT — see [LICENSE](./LICENSE).

## See also

- [Stack-chan official repository](https://github.com/stack-chan/stack-chan)
- [PicoRuby](https://github.com/picoruby/picoruby)
- [R2P2-ESP32](https://github.com/picoruby/R2P2-ESP32)
