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

`bundle exec rake vendor:setup` fetches the two build trees this repo needs
into `vendor/` (gitignored, never hand-placed):

```
vendor/R2P2-ESP32/    bash0C7/R2P2-ESP32, branch stackchan-integration.
                      Device firmware build tree; its own picoruby submodule
                      (branch stackchan-integration, derived from the
                      upstream-PR-track picoruby-ble-esp32-port) carries the
                      StackChan-specific in-tree gems (picoruby-ble-bridge,
                      picoruby-i2s) alongside picoruby-ble itself.
vendor/R2P2-darwin/   bash0C7/R2P2-darwin, branch main. Mac-side PicoRuby VM
                      build harness (vendors picoruby's port-darwin branch
                      internally). See pc/stackchan-pico/README.md. Also
                      holds the iOS control app
                      (vendor/R2P2-darwin/examples/ios/stackchan) — a BLE
                      central written in Ruby, verified against a physical
                      StackChan from a physical iPhone.
```

Four more hardware-driver mrbgems (LCD, PY32 I/O expander, servo, frame
protocol) are separate `bash0C7/picoruby-*` repos fetched straight from
GitHub by the firmware's own build_config (`conf.gem github:`) — no local
clone or vendoring needed for those.

All StackChan business logic lives in a single autostart payload:

```
app/application.rb   Face rendering, the WS2812 LED ring driver, the Si12T
                     head-touch poll with on-device face + LED feedback, the
                     command dispatcher, the BLE peripheral, audio receive,
                     and the cold-boot init sequence.

pc/stackchan-pico/         Unified macOS-side CLI (`stackchan <verb>`), in
                           PicoRuby — CLI + launchd-managed daemon + BLE central.
                           See pc/stackchan-pico/README.md.
pc/stackchan/              CRuby support library for the AI/voice sidecar
                           only (Apple Foundation Model + say/afconvert
                           cannot run under PicoRuby); no CLI here anymore.
pc/sidecar/                The CRuby sidecar process, bridged to the
                           PicoRuby daemon over picoruby-drb.

test/                      Host tests (picotest on a host PicoRuby VM, reusing
                           vendor/R2P2-ESP32's own picoruby submodule).
lib/ruby_class_extract.rb  prism-AST loader for application.rb class bodies.
lib/deploy/                host-side picomodem uploader.
Rakefile                   build, flash, deploy, vendor fetch, and BLE smoke
                           task wrappers.
```

Host tests run the device-side logic on a host PicoRuby VM through picotest. A
CRuby orchestrator extracts the class bodies from `application.rb` with a prism
AST so the device classes can be exercised without the device;
`pc/stackchan-pico/app/ble_client.rb` is extracted the same way for the pc
suite. Device interaction (build, flash, deploy, capture) goes through the
`stackchan-device-*` skills, which wrap the `r2p2:*` Rakefile tasks.

## Quickstart (macOS side)

A single CLI `stackchan` drives the robot. See
[pc/stackchan-pico/README.md](pc/stackchan-pico/README.md) for the full
architecture, env vars, and verb list. `bundle exec rake pc:up` starts both
backends — the CRuby AI/voice sidecar and the PicoRuby daemon, which owns
the BLE connection — under launchd, recreating them every time it runs;
`rake pc:down` stops the backends and removes their launchd plists. The CLI
only attaches to the already-running daemon, connecting to a physical
StackChan by default:

```bash
bundle exec rake pc:up                                   # (re)start the backends under launchd
pc/stackchan-pico/bin/stackchan connect                  # explicit: bring the link up
pc/stackchan-pico/bin/stackchan status                   # observe only
pc/stackchan-pico/bin/stackchan face joy                 # neutral / smile / joy / surprised / sad / angry / closed
pc/stackchan-pico/bin/stackchan led both red solid       # side: left|right|both, mode: solid|blink|breathing|off
pc/stackchan-pico/bin/stackchan servo --yaw-left 50 --pitch-up 30 --time 500
pc/stackchan-pico/bin/stackchan torque on                # off lets you move the head by hand
pc/stackchan-pico/bin/stackchan say "ぼくスタックチャンだよ" --gain 0.1  # speaks + shows subtitle on LCD (first 19 chars)
pc/stackchan-pico/bin/stackchan chat "おはよう"          # Apple Foundation Model reply + face + subtitle
pc/stackchan-pico/bin/stackchan touch listen             # stream `<touch:N>` events as the head sensor fires
pc/stackchan-pico/bin/stackchan demo                     # scripted intro: speak + face + servo + LED cycling
pc/stackchan-pico/bin/stackchan tui                      # interactive servo/face REPL
pc/stackchan-pico/bin/stackchan calibrate --align-only   # torque off → operator aligns forward → torque on
pc/stackchan-pico/bin/stackchan stop                     # explicit: tear the link down
```

### Touch reactions

Head-touch reactions are on-device — the dispatcher polls the Si12T sensor
from its heartbeat loop and updates the face + LED locally the moment a
rising edge fires (no PC round-trip, no perceptible lag even when the BLE
link is idle). Per zone:

| Zone | Face | LED |
|---|---|---|
| 0 | Surprised | both halves, green (300ms pulse) |
| 1 | Angry | right half, red (300ms pulse) |
| 2 | Sad | left half, blue (300ms pulse) |

The PC side only sees the `<touch:N>` BLE notify, so `touch listen` is the
right verb when you want a CLI side-effect (printing events) on top of the
on-device visual feedback.

### Interactive servo console

`stackchan tui` — interactive servo TUI with short commands
(`yl 50`, `pu 30`, `fwd`, `ton` / `toff`, `face joy`, …).

### Calibration

```bash
pc/stackchan-pico/bin/stackchan calibrate --align-only   # daily startup: torque off → align forward → torque on
pc/stackchan-pico/bin/stackchan calibrate --samples 5 --format ruby   # full 5-pose anchor recal, prints constants
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
| 3-zone head touch (Si12T) | yes | on-device face + LED pulse per tap, BLE `<touch:N>` notify to PC |
| WiFi, HTTP, MQTT, WebSocket | no | gems available, wiring pending |
| Camera (GC0308) | no | deferred |
| NFC | no | deferred |

## Audio path

macOS synthesizes speech with `say`, converts 8 kHz mono PCM to G.711 mu-law,
and streams it over BLE using a half-duplex receive-then-play protocol.

The PC side sends `<A:N>` (N = mu-law byte count), waits 1.5 s for the device
heartbeat to pick it up, blasts the bytes in MTU-sized writes, then waits
`N/8000 + 2 s` for playback to finish. The device, on receiving `<A:N>`,
replies `<A:ready>`, sleeps `T = (N × 1000 / 8000) + 3000 ms` (main task fully
static during this window), drains the receive queue, and plays the buffer. The
phase separation prevents the btstack FreeRTOS thread and the PicoRuby main
task from racing on the mruby heap.

The AW88298 Class-D amplifier requires its boost rail (SY7088, via AW9523) and
its 1.8 V digital rail (AXP2101 ALDO1) powered at cold-boot. The I2S link uses
BCLK on GPIO34, WS on GPIO33, and data-out on GPIO13 with no MCLK. Volume is
controlled by the macOS-side `--gain` parameter (default 0.1).

## Latency and remaining headroom

A `face` command over BLE takes 0.42 s (neutral) to 0.68 s (joy), median of
eight rounds on a CoreS3. The `led` verb travels the same BLE path and draws
nothing; it takes 0.18 s, and that is the floor. The remaining 0.24-0.50 s is
the LCD repaint, and it scales with how many drawing primitives a face is made
of rather than with how many pixels it covers.

Numbers drift 15-25% between sessions, so compare runs taken in the same
session and treat a figure quoted from an older one as a rough guide only.
`ROUNDS=8 tools/face_profile.zsh` produces the table; `ruby
tools/face_spi_cost.rb` counts a face's SPI calls on the host with no device
attached.

The repaint is PicoRuby executing the geometry — the Bresenham and ellipse
loops that decide which spans to fill. Both options below attack that, and
neither is applied: the device runs the straightforward per-primitive form.

### Option: pre-render each face's band

Faces are static, so the geometry recomputes, on every change, a byte string
that is always the same. Rendering each face's band once into RGB565 and
blitting the stored copy removes the geometry entirely, leaving the 0.18 s
floor plus one transfer. This is the whole 0.24-0.50 s, so it is the larger
win by far.

The band is 136x74 px — 20 128 bytes per face, about 141 KB for all seven.
That fits the 8 MB PSRAM comfortably, but the bytes have to come from
somewhere: either generated on the host and baked into the image, or drawn
once on the device and cached on first use. Which of the two is the open
question, and nothing has been built.

### Option: compose the redraw offscreen

Collecting a redraw into an offscreen buffer and blitting it in one
transaction takes a face from 207-428 `SPI#write` calls down to 10. Measured,
that is worth 7-9%: 0.39 s neutral and 0.62 s joy, against 0.42 s and 0.68 s
for the per-primitive form in the same session. Real, but small — the panel
transfer is not where the time goes, so removing almost all of it moves little.

This was built and then reverted, so it can be recovered rather than rewritten:
the driver side is `8a2fced` in `bash0C7/picoruby-ili9342` (reverted by
`25e29b4`), the application side is `d4ae838` and `ceff876` here (reverted by
`c17a3c2`). Reverting those reverts restores a working, tested implementation.

It was dropped on cost, not on correctness. It grows the driver from 345 to 446
lines, and both constraints in the next section are hazards it introduced —
one of them as a boot loop. Weigh that against 7-9% before restoring it; if the
pre-rendered band above is built instead, this becomes redundant.

### Constraints to know before trying either

- The FreeRTOS task that runs the mruby VM has an 8 KB stack
  (`PICORB_TASK_STACK_SIZE`, `components/picoruby-esp32/picoruby-esp32.c`). One
  nested VM execution costs about 3.1 KB — `mrb_vm_exec`'s Xtensa prologue is
  `entry a1, 0xb50`, 2896 bytes. A construct that yields a block from C, such as
  `Array.new(n) { ... }` or `String#dup`, therefore adds a whole frame, and from
  inside a drawing path that overflows the stack. The symptom is a boot loop
  reporting `stack overflow in task picoruby_task`, roughly 5 s after
  advertising starts, which is the first blink.
- mruby's `String#[]=` copies in proportion to the size of the string it splices
  into, not the size of the slice (`str_replace_partial` in `src/string.c`).
  Splicing rows into a single 20 KB buffer costs about 2.5 ms per primitive at
  PSRAM speed; per-row strings avoid it. This is invisible on a host, where the
  buffer fits in L1.

## Hardware

[M5Stack StackChan AI Desktop Robot (Switch Science 11129)](https://www.switch-science.com/products/11129):

- SoC: ESP32-S3 dual-core LX7 at 240MHz, 16MB Flash, 8MB Quad PSRAM
- LCD: 2.0" IPS 320x240 (ILI9342)
- LEDs: 12 WS2812 RGB
- PMIC: AXP2101
- IO expanders: AW9523 and PY32
- Audio: AW88298 Class-D amplifier, 1W speaker
- BLE 5.0 LE (NimBLE ESP32 port)

## Development environment

macOS only. The Rakefile assumes macOS paths and the macOS
[`serialport`](https://github.com/larskanis/ruby-serialport) gem. It needs
Xcode with the Swift toolchain (for the `picoruby-ble` Darwin port used by
`pc/stackchan-pico`'s BLE central), esp-idf v5.4 at `~/esp/esp-idf`, Ruby
4.0+, and Bundler. Building and controlling the device fetches its build
trees on demand via `bundle exec rake vendor:setup` (see "Code layout"
above) rather than requiring hand-placed sibling clones.

## Dependencies

Everything below is fetched on demand — no hand-placed sibling clones needed.
Repo/ref pins are the single source of truth for what a build actually runs;
this table exists so that fact doesn't have to be re-derived from Rakefiles
and build_configs each time.

| Repo | Ref | Role | Pinned by |
|---|---|---|---|
| [bash0C7/R2P2-ESP32](https://github.com/bash0C7/R2P2-ESP32) | branch `stackchan-integration` | ESP32 device firmware build tree | `Rakefile` (`R2P2_ESP32_REPO`/`R2P2_ESP32_REF`) |
| [bash0C7/R2P2-darwin](https://github.com/bash0C7/R2P2-darwin) | branch `main` | Mac-side PicoRuby VM build harness | `Rakefile` (`R2P2_DARWIN_REPO`/`R2P2_DARWIN_REF`) |
| [bash0C7/picoruby](https://github.com/bash0C7/picoruby) | branch `stackchan-integration` | PicoRuby itself, device side | R2P2-ESP32's `components/picoruby-esp32/picoruby` submodule pin |
| [bash0C7/picoruby](https://github.com/bash0C7/picoruby) | branch `port-darwin` | PicoRuby itself, Mac side (BLE + mbedtls + io-console + machine darwin ports) | R2P2-darwin's own `rake setup` |
| [bash0C7/picoruby-ili9342](https://github.com/bash0C7/picoruby-ili9342) | branch `stackchan-integration` (moving ref) | LCD driver | R2P2-ESP32's `build_config/xtensa-esp-picoruby.rb` |
| [bash0C7/picoruby-py32-io-expander](https://github.com/bash0C7/picoruby-py32-io-expander) | tag `v0.1.0` | PY32 I/O expander driver | same build_config |
| [bash0C7/picoruby-stackchan-protocol](https://github.com/bash0C7/picoruby-stackchan-protocol) | tag `v0.1.0` | BLE frame protocol (`FrameParser`) | same build_config |
| [bash0C7/picoruby-scservo](https://github.com/bash0C7/picoruby-scservo) | tag `v0.1.0` | Servo driver | same build_config |

The WS2812 LED ring driver (`picoruby-stackchan-led`) is not a separate repo
dependency — it is inlined into this repo's `app/application.rb`.

## Related repositories

### [R2P2-ESP32 fork](https://github.com/bash0C7/R2P2-ESP32)

Adds on top of upstream:

- `sdkconfigs/cores3`: CoreS3 SoC overlay (Quad PSRAM 8MB, 16MB Flash,
  USB-Serial-JTAG console).
- `sdkconfigs/bt_btstack`: BLE enablement with the ROM coex hook disabled, which
  avoids a `LoadProhibited` panic in `coex_schm_lock` on BLE-only builds with
  IDF v5.4 and ESP32-S3.
- `build_config/xtensa-esp-picoruby.rb` (on the `stackchan-integration` branch):
  wires the 4 standalone driver gems above plus `picoruby-ble` /
  `picoruby-ble-uart` / `picoruby-i2s`.
- Points its `components/picoruby-esp32/picoruby` submodule at the picoruby
  fork's `stackchan-integration` branch below.

### [picoruby fork](https://github.com/bash0C7/picoruby)

BLE support (`mrbgems/picoruby-ble/`), tracked on two branches, both rebased
onto upstream picoruby/picoruby's `master`:

- `stackchan-integration` — the ESP32 (NimBLE) peripheral port, derived from
  the upstream-PR-track [`picoruby-ble-esp32-port`](https://github.com/picoruby/picoruby/pull/427)
  branch, plus the StackChan-specific in-tree gems (`picoruby-i2s`,
  `picoruby-ble-bridge`).
- `port-darwin` — the macOS (CoreBluetooth) central/peripheral port used by
  `pc/stackchan-pico`'s BLE central and `vendor/R2P2-darwin`. The central
  role can receive a GAP disconnect but cannot initiate one (no such API
  exists in this port yet) — `StackchanCentral#disconnect` in
  `pc/stackchan-pico/app/ble_client.rb` is therefore a local-state-only
  no-op; reconnect-from-ACK-timeout relies on the peripheral's own
  supervision timeout, not on the central closing the link.

### [rb-corebluetooth-mac](https://github.com/bash0C7/rb-corebluetooth-mac)

A macOS CoreBluetooth binding for Ruby, used for BLE dev/debug tooling
(e.g. `repro/flood_rx.rb`). The operational PC-side BLE transport is the
native `picoruby-ble` darwin port used by `pc/stackchan-pico`.

## License

MIT, see [LICENSE](./LICENSE).

## See also

- [Stack-chan official repository](https://github.com/stack-chan/stack-chan)
- [PicoRuby](https://github.com/picoruby/picoruby)
- [R2P2-ESP32](https://github.com/picoruby/R2P2-ESP32)
