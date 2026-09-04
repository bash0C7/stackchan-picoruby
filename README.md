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
vendor/R2P2-ESP32/    bash0C7/R2P2-ESP32, branch c-primitives-verified.
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
app/application.rb   Face rendering, head-touch reactions, the command
                     dispatcher, the BLE peripheral, audio receive, and the
                     cold-boot init sequence.
mrbgems/             picoruby-stackchan-led (WS2812 ring), picoruby-si12t
                     (head touch), picoruby-aw88298 (amp + mu-law decode in C),
                     and picoruby-stackchan-shared (frame codec, used by the
                     PC side too). The two pure-Ruby drivers are prepended to
                     application.rb by the Rakefile before compiling app.mrb;
                     aw88298 is compiled into the firmware.

pc/stackchan-pico/         Unified macOS-side CLI (`stackchan <verb>`), in
                           PicoRuby — CLI + launchd-managed daemon + BLE central.
                           See pc/stackchan-pico/README.md.
pc/stackchan/              CRuby support library for the AI/voice sidecar
                           only (Apple Foundation Model + say/afconvert
                           cannot run under PicoRuby).
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

## Setting up a new machine

Prerequisites are listed under "Development environment" below; install those
first. Nothing here needs hand-placed sibling clones — every dependency is
either fetched by a rake task or pulled from GitHub at build time.

```bash
git clone https://github.com/bash0C7/stackchan-picoruby.git
cd stackchan-picoruby
bundle install
bundle exec rake vendor:setup          # clone both build trees and the picoruby
                                       # each one builds from (several GB, slow)
```

### Device (ESP32-S3)

```bash
bundle exec rake r2p2:setup            # 10-20 min; first time, and after a target switch
bundle exec rake r2p2:build_flash_appmrb SRC=app/application.rb
```

`r2p2:setup` rebuilds the host mruby and runs `idf.py set-target esp32s3`.
Skipping it leaves the target at the default `esp32`, which fails to link with an
IRAM overflow. The second command builds the firmware and bakes
`app/application.rb` into the littlefs storage partition as `/home/app.mrb`, so
the robot autostarts it. Both need the CoreS3 attached over USB-C.

Day-to-day iteration on the application alone does not reflash the firmware — use
the `/stackchan-device-iterate` skill, which uploads only `app.mrb`.

### macOS side

The PicoRuby VM that owns the BLE link has to be built and then wrapped in an app
bundle, because CoreBluetooth is only granted through macOS TCC and that grant
binds to a bundle identity:

```bash
bundle exec rake pc:vm_build           # build the PicoRuby VM under vendor/R2P2-darwin
bundle exec rake pc:app_bundle         # -> ~/Applications/StackchanPico.app
bundle exec rake pc:up                 # start the backends under launchd
pc/stackchan-pico/bin/stackchan status
pc/stackchan-pico/bin/stackchan face joy
```

Re-run `pc:app_bundle` after every `pc:vm_build`: the bundle is ad-hoc signed, and
the signature binds to the exact bytes of the binary.

The first `pc:up` after a device flash can report that the daemon did not answer
within its timeout while the BLE link is still coming up. Run it again; it is
idempotent and recreates the launchd jobs each time.

### Tests

```bash
bundle exec rake picotest:build        # host picoruby VM from build_config/picoruby-test.rb
bundle exec rake test                  # picotest: device / pc / shared suites
bundle exec rake test:host             # CRuby-only tools and the class extractor
```

`rake test` reads the source of `picoruby-scservo`, which is fetched from GitHub at
firmware-build time rather than vendored here. It finds it in the firmware build tree, so run a device
build once first, or point `SCSERVO_RB` at your own clone of `picoruby-scservo`.

The test VM builds as `host-picotest` and the firmware's own host tools build as
`host`, so a firmware build cannot reach it. They shared `build/host` until CI
built both in one job and every suite came up `uninitialized constant Picotest`:
mruby does not treat MRUBY_CONFIG as a dependency of objects it has already
built, so whichever config ran last simply kept what the other had left.

### Optional

`bash0C7/rb-corebluetooth-mac` gives a Bash-callable BLE central for ad-hoc
BLE debugging. It needs `bundle install && bundle exec rake compile` in its own
checkout before first use, and again after any Ruby ABI change.

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
pc/stackchan-pico/bin/stackchan say "ぼくスタックチャンだよ"   # speaks + shows subtitle on LCD (first 19 chars)
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

## Known issues

The BLE link itself is not one of these. A full pass over every verb — status,
face, led, torque, servo on both axes, read-back, say, selftest, stop and head
touch — completes without a single ACK timeout or retry.

- There is no retry path: `ble_client.rb` raises `TimeoutError` on an ACK
  timeout and the CLI command fails rather than the frame being resent once.
  This is a gap in the code, not an observed symptom; it has no effect until a
  frame is actually dropped.
- `<A:done>` taking about 45 s on the first `say` after a long idle rests on a
  single observation after ten hours. It has not recurred, and a `say` on a
  warm device answers in seconds, so recreating a long idle is what would
  settle whether this is still real.
- `rake pc:up` can report that the daemon "is listening but did not answer
  status". `Daemon#start` primes the sidecar between opening the drb port and
  announcing itself, and a sidecar TCP connect that hangs instead of failing
  fast freezes the whole daemon VM with the port already open. Running
  `rake pc:up` again clears it.

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

That window is sized from an assumed 8000 bytes/s blast, while the PC paces at a
nominal 9000 bytes/s and measures slower than that. Long clips can therefore
outrun the window and lose their tail; where the ceiling actually falls has not
been characterised. The limit is a byte count, so it buys half as many seconds
of speech for every doubling of the sample rate.

The AW88298 Class-D amplifier requires its boost rail (SY7088, via AW9523) and
its 1.8 V digital rail (AXP2101 ALDO1) powered at cold-boot. The I2S link uses
BCLK on GPIO34, WS on GPIO33, and data-out on GPIO13 with no MCLK. Volume is
controlled by the macOS-side `--gain` parameter (default 0.05). Nothing clips
digitally at any gain — `say` peaks around 19900 of full scale and neither the
resample nor the mu-law encode reaches the rails — so audible break-up means the
speaker is being overdriven, and the fix is amplitude, not the codec.

## Latency

A `face` command over BLE takes 0.16 s (neutral) to 0.21 s (joy), median of
eight rounds. `led` travels the same path and draws nothing: 0.18 s. The faces
sit at that floor, so the LCD repaint no longer stands out above the BLE round
trip.

Numbers drift 15-25% between sessions; only compare runs from the same
session. `ROUNDS=8 tools/face_profile.zsh` produces the table.

| face | seconds | with the primitives in Ruby |
|---|---|---|
| neutral | 0.16 | 0.42 |
| surprised | 0.16 | 0.42 |
| angry | 0.17 | 0.55 |
| smile | 0.18 | 0.56 |
| sad | 0.18 | 0.52 |
| joy | 0.21 | 0.67 |
| `led` (floor) | 0.18 | 0.19 |

Both columns are medians of the same eight-round run, measured in one session
either side of the firmware change, so they are comparable. The device-side
ACK in the daemon log moved the same way: 344-624 ms down to 100-164 ms.

A rebuild from the same sources, measured later in that session, gave 0.17-0.21 s
against a 0.19 s floor: the ordering across faces is stable, individual faces move
by about 0.02 s between runs.

What went away is the time PicoRuby spent interpreting Bresenham and
midpoint-ellipse loops. `picoruby-ili9342` issues the address window, RAMWR
and pixel stream from C, one call per shape. Neither pixel count nor
`SPI#write` count ever explained the cost (cutting the calls from ~400 to 10
was worth 7-9%); primitive count did.

Two device-only constraints bind anything that goes back onto the draw path in
Ruby:

- The mruby VM task has an 8 KB stack; a construct that yields a block from
  C (`Array.new(n) { }`, `String#dup`) nests the VM and costs ~3.1 KB. Inside
  a drawing path that is a boot loop (`stack overflow in task picoruby_task`).
- `String#[]=` copies in proportion to the receiver, not the slice. Splicing
  rows into one 20 KB buffer costs ~2.5 ms each; per-row strings avoid it.

A third constraint binds the C side: `picoruby-spi`'s ESP32 port creates the
bus with `max_transfer_sz` left at 0 and DMA on, so `esp_driver_spi` allocates
a single DMA descriptor and rejects any transfer over 4092 bytes. The driver's
pixel chunk is 1024 pixels (2048 bytes) to stay under it.

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
| [bash0C7/R2P2-ESP32](https://github.com/bash0C7/R2P2-ESP32) | branch `c-primitives-verified` | ESP32 device firmware build tree | `Rakefile` (`R2P2_ESP32_REPO`/`R2P2_ESP32_REF`) |
| [bash0C7/R2P2-darwin](https://github.com/bash0C7/R2P2-darwin) | branch `main` | Mac-side PicoRuby VM build harness | `Rakefile` (`R2P2_DARWIN_REPO`/`R2P2_DARWIN_REF`) |
| [bash0C7/picoruby](https://github.com/bash0C7/picoruby) | branch `stackchan-integration` | PicoRuby itself, device side | R2P2-ESP32's `components/picoruby-esp32/picoruby` submodule pin |
| [bash0C7/picoruby](https://github.com/bash0C7/picoruby) | branch `port-darwin` | PicoRuby itself, Mac side (BLE + mbedtls + io-console + machine darwin ports) | R2P2-darwin's own `rake setup` |
| [bash0C7/picoruby-ili9342](https://github.com/bash0C7/picoruby-ili9342) | branch `main` | LCD driver, drawing primitives in C | R2P2-ESP32's `build_config/xtensa-esp-picoruby.rb` |
| [bash0C7/picoruby-py32-io-expander](https://github.com/bash0C7/picoruby-py32-io-expander) | tag `v0.1.0` | PY32 I/O expander driver | same build_config |
| [bash0C7/picoruby-stackchan-protocol](https://github.com/bash0C7/picoruby-stackchan-protocol) | tag `v0.1.0` | BLE frame protocol (`FrameParser`) | same build_config |
| [bash0C7/picoruby-scservo](https://github.com/bash0C7/picoruby-scservo) | tag `v0.1.0` | Servo driver | same build_config |

The WS2812 and Si12T drivers are mrbgems in this repo's `mrbgems/` bundled
into `app.mrb` at compile time. `picoruby-aw88298` has a C part, so the
firmware build_config fetches it from this repo:
`conf.gem github: 'bash0C7/stackchan-picoruby', path: 'mrbgems/picoruby-aw88298'`.

### Staying reproducible

Two of those pins can be satisfied on one disk and nowhere else. A submodule sha
becomes fetchable only when someone pushes a branch containing it, and committing
the pointer says nothing about whether that happened; a gem `branch:` disappears
when its pull request is merged with "delete branch". Either one leaves a tree
that builds here forever and stops a fresh clone dead.

`tools/check_deps_pushed.sh` asks both questions, counting only URLs whose host is
github.com — the clones on this machine sit under `~/dev/src/github.com/...`, so a
remote naming another directory on this disk spells the string while proving
nothing. It walks every pin, including the ten inside picoruby, and resolves the
build trees through the main checkout so it answers the same from a worktree.

It also reads the vendored trees themselves, because a tree can disagree with its
own configuration in two more ways. A submodule checked out somewhere other than
the sha its parent pins means the firmware on the bench is nobody else's build —
the state you are in mid-way through switching a lineage. And a `conf.gem` clone
under `build/repos` is fetched once and never pulled, so a ref that resolves on
GitHub says nothing about the commit the build actually compiles. Both fail.

Uncommitted edits in a vendored tree fail too: everything under `vendor/` is a
copy of someone else's work, so an edit there is code no clone can get, which is
a worse version of the unpushed pin since there is no commit at all. Two things
are named rather than failed — untracked leftovers from switching lineages, and
a file a committed patch is applied to at build time, which a fresh clone
reproduces on its own.

It runs in two places. Before a push, `tools/hooks/pre_push_guard.sh` — wired in
`.claude/settings.json` — runs it in `--pins-only` mode and refuses the push if a
pin would not survive. Publishing a pin is itself a push, so that one command
gets through by saying so: `STACKCHAN_DEPS_GUARD=off git -C … push …`. And
`.github/workflows/deps.yml` clones the firmware tree from nothing on every push
and weekly, running the whole script, which catches a ref that rots while nobody
is looking.

`.github/workflows/firmware.yml` answers the larger question the dependency
check cannot: it builds the firmware in `espressif/idf:v5.4.2` from a fresh
clone and runs both suites, so "it works on another machine" is measured rather
than assumed. It does not flash and there is no CoreS3 on a runner, so the bench
is still the only thing that can say whether the robot moves. A full esp-idf
build is tens of minutes, so it runs weekly and on demand rather than per push.

`test-host/deps_guard_test.rb` builds git fixtures that are broken in each of
those ways and asserts the guard says so.

## Related repositories

### [R2P2-ESP32 fork](https://github.com/bash0C7/R2P2-ESP32)

Adds on top of upstream:

- `sdkconfigs/cores3`: CoreS3 SoC overlay (Quad PSRAM 8MB, 16MB Flash,
  USB-Serial-JTAG console).
- `sdkconfigs/bt_nimble`: BLE enablement with the ROM coex hook disabled, which
  avoids a `LoadProhibited` panic in `coex_schm_lock` on BLE-only builds with
  IDF v5.4 and ESP32-S3.
- `build_config/xtensa-esp-picoruby.rb` (on the `c-primitives-verified` branch):
  wires the 4 standalone driver gems above plus `picoruby-ble` /
  `picoruby-ble-uart` / `picoruby-i2s`.
- Points its `components/picoruby-esp32/picoruby` submodule at `7258676` on the
  picoruby fork's `stackchan-integration` branch below. The branch head has moved
  past that commit onto a lineage that boot-loops on this board; see HANDOFF.

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

A macOS CoreBluetooth binding for Ruby, used for BLE dev/debug tooling.
The operational PC-side BLE transport is the
native `picoruby-ble` darwin port used by `pc/stackchan-pico`.

## License

MIT, see [LICENSE](./LICENSE).

## See also

- [Stack-chan official repository](https://github.com/stack-chan/stack-chan)
- [PicoRuby](https://github.com/picoruby/picoruby)
- [R2P2-ESP32](https://github.com/picoruby/R2P2-ESP32)
