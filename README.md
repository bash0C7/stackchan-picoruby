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
+-----------+     BLE NUS, pair 6e400004/5 (dRuby)      +---------------------+
|  macOS    | <--------------------------------------> |  CoreS3 / R2P2      |
|  iPhone   |                                          |  PicoRuby + mrbgems |
|  Watch    |                                          |  LCD / LED / servo  |
+-----------+                                          |  / BLE / speaker    |
                                                       +---------------------+
```

The CoreS3 is an I/O endpoint. It renders faces, drives the 12-pixel WS2812 RGB
ring, moves the two feedback servos, plays audio through the AW88298 amplifier,
advertises the Nordic UART Service, and listens for control frames.

The controllers — the macOS daemon and the iPhone and Apple Watch apps — are
the orchestrators. They send control frames (face, LED, servo position, audio)
and read the reply lines (an ACK or ERR line plus a detail line).

Every command, reply, head touch and audio clip travels as dRuby over BLE on the
service's characteristic pair (`6e400004` write, `6e400005` notify).
The controller calls the robot's front object; a command is a Hash in the
key-value vocabulary that the FrameParser in the
`mrbgems/picoruby-stackchan-protocol` gem reads, and the reply is the lines
the robot answers with.

Audio is a sequence of dRuby calls: `audio_begin`, `audio_chunk` (2048 bytes
each), `audio_play`, then polling `audio_done`.

## Code layout

`bundle exec rake vendor:setup` fetches the two build trees this repo needs
into `vendor/` (gitignored, never hand-placed):

```
vendor/R2P2-ESP32/    bash0C7/R2P2-ESP32. Device firmware build tree; its own
                      picoruby submodule carries picoruby-ble and picoruby-i2s.
vendor/R2P2-darwin/   bash0C7/R2P2-darwin. Apple platform: builds the Mac
                      PicoRuby VM and the iOS / watchOS apps from this repo's
                      apps/ and build_config/ (vendors its own picoruby). See
                      pc/stackchan-pico/README.md.
```

The firmware's gem list is `build_config/esp32-stackchan.rb`; the `r2p2:*`
tasks hand it to R2P2-ESP32 as `R2P2_BUILD_CONFIG`, and R2P2-ESP32's own
default config names no StackChan gem. Three hardware-driver mrbgems (LCD,
PY32 I/O expander, servo) are separate `bash0C7/picoruby-*` repos that config
fetches straight from GitHub (`conf.gem github:`) — no local clone or
vendoring needed for those. The BLE frame protocol gem
(`mrbgems/picoruby-stackchan-protocol`), the AOT kernels and
picoruby-multicore go in as gem dirs; multicore's ESP32 port is compiled by
the IDF component through `R2P2_EXTRA_SRCS`.

The robot's behaviour is one DSL file; the engine gem does everything else:

```
apps/robot/app.rb    The autostart payload: requires and one
                     `StackChan.robot do |bot| ... end.run` naming the faces,
                     the face index, the head-touch reactions and the blink.
mrbgems/             picoruby-stackchan-robot (the engine: DSL, cold-boot
                     init sequence, BLE peripheral, command dispatcher, face
                     rendering, audio playback, tick loop, dRuby front),
                     picoruby-stackchan-led (WS2812 ring), picoruby-si12t
                     (head touch), picoruby-aw88298 (amp + mu-law playback),
                     picoruby-drb-ble (dRuby over BLE),
                     picoruby-stackchan-controller (the Mac-side engine:
                     `StackChan.controller` DSL, BLE central, link
                     hold/keepalive/reconnect, daemon, CLI, calibration,
                     send builder and error hierarchy, which the Mac loads
                     as source). The device-side gems are prepended to the
                     app by the Rakefile before compiling app.mrb.
apps/mac/app.rb      The Mac's behaviour: one `StackChan.controller do |c|
                     ... end` naming the CLI's actions (face, led, servo,
                     torque, selftest, say, chat, demo), the link hold time
                     and the reply handler.
apps/ios/            The iPhone app: app.rb (one `StackChan.controller`) plus
                     the Swift shell and XcodeGen project.yml.
apps/watchos/        The Apple Watch app, laid out the same way.
aot/kernels/         Ruby compiled ahead of time (spinel -> suppify) into the
                     firmware: mu-law decode on core 1, glyph expansion on
                     core 0. See aot/README.md.
build_config/        picoruby build configs: the firmware
                     (esp32-stackchan.rb), the host test VM, the Mac VM and
                     the iOS / watchOS VMs.

pc/stackchan-pico/         Launchd and process glue for the macOS side: the
                           `stackchan` wrapper and the boot files. The daemon
                           loads the controller gem and apps/mac/app.rb; the
                           CLI loads only the controller's cli.rb and
                           calibration.rb and talks to the daemon. See
                           pc/stackchan-pico/README.md.
pc/stackchan/              CRuby support library for the AI/voice sidecar
                           only (Apple Foundation Model + say/afconvert
                           cannot run under PicoRuby).
pc/sidecar/                The CRuby sidecar process, bridged to the
                           PicoRuby daemon over picoruby-drb.

test/                      Host tests (picotest on a host PicoRuby VM, reusing
                           vendor/R2P2-ESP32's own picoruby submodule).
test-host/                 CRuby tests for the Rakefile's host-side tools.
acceptance/                The pre-merge device check: lock.yml pins the one
                           firmware, runner.rb and ops.rb drive it, results/
                           holds the reports.
tools/                     Measurement and demo scripts, the dependency guard
                           and the push hook.
lib/                       Ruby the Rakefile uses: the picomodem uploader
                           (lib/deploy/), board and lock lookup, QEMU gate,
                           flash identity and the launchd lifecycle.
Rakefile                   build, flash, deploy, vendor fetch, and BLE smoke
                           task wrappers.
```

Host tests run the device-side logic on a host PicoRuby VM through picotest.
The device suite loads the robot gem (all but its `< BLE` peripheral) with
fakes for the display, LEDs, servos and touch, and evaluates
`apps/robot/app.rb` with its requires stripped and `Robot#run` stubbed, so the
app's handlers are exercised without the device. The pc suite loads the
controller gem's mrblib and `apps/mac/app.rb` as they are, against a `BLE`
stub, `FakeRadio` (which can drop the link and refuse connects) and
`FakeRobotRadio`, with an injected clock. Device interaction (build, flash, deploy, capture) goes through the
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
bundle exec rake r2p2:build_flash_appmrb SRC=apps/robot/app.rb
```

`r2p2:setup` rebuilds the host mruby and runs `idf.py set-target esp32s3`.
Skipping it leaves the target at the default `esp32`, which fails to link with an
IRAM overflow. The second command builds the firmware and bakes
`apps/robot/app.rb` into the littlefs storage partition as `/home/app.mrb`, so
the robot autostarts it. Both need the CoreS3 attached over USB-C.

Every task that flashes firmware first boots the same tree under QEMU
(`r2p2:qemu_check`) and refuses to flash on a FAIL. The gate runs
`rake qemu:setup`, which downloads the pinned QEMU into `build/qemu/`; on macOS
that QEMU needs `brew install libgcrypt glib pixman sdl2 libslirp`.

Every task that opens the serial port finds the CoreS3 by its USB serial number,
not by port name: port names follow the USB socket, and every ESP32-S3 enumerates
under the same product name. Put the CoreS3's serial in `.stackchan-usb-serial`
(gitignored) or `STACKCHAN_USB_SERIAL`; `rake r2p2:boards` lists the boards on USB
without opening any port. With several ESP32-S3 boards attached and no serial
set, the tasks stop rather than pick one. They also take the
`~/.cache/r2p2-device-locks/esp32.lock` that
[R2P2-dev-harness](https://github.com/bash0C7/R2P2-dev-harness) takes, so
sessions driving boards from either repository wait for each other.

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

The iPhone and Apple Watch apps are `apps/ios` and `apps/watchos`: one
`App = StackChan.controller do |c| … end` each, one button per action. They
build on a Mac with Xcode and XcodeGen through `vendor/R2P2-darwin`:

```bash
bundle exec rake ios:lib ios:gen ios:build   # Simulator build
bundle exec rake ios:device:all        # the connected iPhone (DEVELOPMENT_TEAM in apps/ios/project.yml)
bundle exec rake watchos:device:all    # the connected Apple Watch
```

`rake ios:run` (and so `ios:all`) stops at `open -a Simulator`. To build and
start an app in the Simulator, use the `stackchan-apple-simulator` skill: rake
makes the VM and the Xcode project, and Xcode MCP (`.mcp.json`) builds, starts
the app with `-StackchanBatch "actions"` and reads its console.
Device builds are signed and need a valid Apple Development certificate.

Launched with `-StackchanBatch "connect;face joy"` an app runs those actions,
prints each output line as `[batch] <line>`, then `[batch] end`, and exits;
`rake acceptance:darwin` runs the device builds that way. It is optional: the
verdict does not need it.

Re-run `pc:app_bundle` after every `pc:vm_build`: it copies the new VM into the
bundle and signs it ad hoc with the designated requirement
`identifier "com.bash0c7.stackchanpico"`, which is what the TCC grant follows.

`pc:up` succeeds once the daemon answers `status` with `connects` of at least 1.
A `link=busy` answer fails it unless `ALLOW_BUSY=1`. It is idempotent and
recreates the launchd jobs each time.

### Tests

```bash
bundle exec rake picotest:build        # host picoruby VM from build_config/picoruby-test.rb
bundle exec rake test                  # rigor:check, then picotest: device / pc suites and each gem's own
SUITE=pc FILTER=central bundle exec rake test   # one suite, test files whose name contains FILTER
bundle exec rake test:host             # CRuby-only tools
```

`rake test` reads the source of `picoruby-scservo`, which is fetched from GitHub at
firmware-build time rather than vendored here. It finds it in the firmware build tree, so run a device
build once first, or point `SCSERVO_RB` at your own clone of `picoruby-scservo`.

The test VM builds as `host-picotest` and the firmware's own host tools build as
`host`, so a firmware build cannot reach it. They are separate because mruby
does not treat MRUBY_CONFIG as a dependency of objects it has already built:
with one build directory, whichever config ran last keeps what the other
left, and every suite fails with `uninitialized constant Picotest`.

### Optional

`bash0C7/rb-corebluetooth-mac` gives a Bash-callable BLE central for ad-hoc
BLE debugging. It needs `bundle install && bundle exec rake compile` in its own
checkout before first use, and again after any Ruby ABI change.

## Quickstart (macOS side)

A single CLI `stackchan` drives the robot. Its verbs are the actions declared
in `apps/mac/app.rb` plus the built-ins `connect`, `status`, `stop`, `raw`,
`calibrate`, `remote`, `touch` and `tui`; `stackchan` with no verb lists them,
which needs the daemon running. See
[pc/stackchan-pico/README.md](pc/stackchan-pico/README.md) for the full
architecture, env vars, link lifecycle and exit codes. `bundle exec rake pc:up` starts both
backends — the CRuby AI/voice sidecar and the PicoRuby daemon, which owns
the BLE connection — under launchd, recreating them every time it runs;
`rake pc:down` stops the backends and removes their launchd plists. The CLI
only attaches to the already-running daemon, connecting to a physical
StackChan by default:

```bash
bundle exec rake pc:up                                   # (re)start the backends under launchd
pc/stackchan-pico/bin/stackchan connect                  # explicit: bring the link up
pc/stackchan-pico/bin/stackchan status                   # one key=value line: link=held connects=1 ...
pc/stackchan-pico/bin/stackchan face joy                 # neutral / smile / joy / surprised / sad / angry
pc/stackchan-pico/bin/stackchan led both red solid       # side: left|right|both, mode: solid|blink|breathing|off
pc/stackchan-pico/bin/stackchan servo --yaw-left 50 --pitch-up 30 --time 500
pc/stackchan-pico/bin/stackchan torque on                # off lets you move the head by hand
pc/stackchan-pico/bin/stackchan say "ぼくスタックチャンだよ"   # speaks + shows subtitle on LCD (first 19 chars)
pc/stackchan-pico/bin/stackchan chat "おはよう"          # Apple Foundation Model reply + face + subtitle
pc/stackchan-pico/bin/stackchan touch listen --count 1 --timeout 30   # prints `touch zone=0 (back)` per tap
pc/stackchan-pico/bin/stackchan demo                     # scripted intro: speak + face + servo + LED cycling
pc/stackchan-pico/bin/stackchan tui                      # one action per line
pc/stackchan-pico/bin/stackchan calibrate --align-only   # torque off → operator aligns forward → torque on
pc/stackchan-pico/bin/stackchan stop                     # the daemon exits
```

The daemon holds the BLE link only while it is in use: the first action
connects, a keepalive runs every second while actions keep coming, and `c.hold` ms
(10 s in `apps/mac/app.rb`) after the last one the keepalive stops and the
robot releases the link. The next action reconnects. When the robot is held
by another central (another Mac, the iOS app) or cannot be reached, the verb
prints `busy: …` and exits 8.

### Touch reactions

Head-touch reactions are on-device — the robot polls the Si12T sensor every
50 ms from its 20 ms link loop and updates the face + LED locally the moment a
rising edge fires (no PC round-trip, no perceptible lag even when the BLE
link is idle). Per zone:

| Zone | Face | LED |
|---|---|---|
| 0 | Surprised | both halves, green (300ms pulse) |
| 1 | Angry | right half, red (300ms pulse) |
| 2 | Sad | left half, blue (300ms pulse) |

The robot queues each touch and the controller collects the queue with its
keepalive, about once a second, so `touch listen` is the
right verb when you want a CLI side-effect (printing events) on top of the
on-device visual feedback. It prints `touch zone=N (back|right|left)` per
tap, exits 0 after `--count` taps, and exits 1 on `--timeout` seconds or when
the link is released.

### Interactive servo console

`stackchan tui` reads one action per line with its arguments, the same words
as on the command line (`face joy`, `servo --yaw-left 50 --time 500`,
`torque off`); `h` lists the verbs and `q` quits.

### Calibration

```bash
pc/stackchan-pico/bin/stackchan calibrate --align-only   # daily startup: torque off → align forward → torque on
pc/stackchan-pico/bin/stackchan calibrate --samples 5 --format ruby   # full 5-pose anchor recal, prints constants
```

### Ambient demo (event/booth idle loop)

Two standalone Ruby scripts drive an unattended idle demo against the running
`stackchan` daemon — deterministic, no AI, no browser:

```bash
tools/ambient_demo.rb       # random LED colors + occasional face/head moves
tools/phrase_announcer.rb   # speaks a random fixed phrase every 30s
```

`ambient_demo.rb` waits for BLE, engages torque, then loops forever:
LED color/side/mode changes every 4-9s, face flips between smile/joy every
12-25s, and the head moves to a random yaw/pitch every 30-70s (infrequent on
purpose so the servos don't wear/overheat). Ctrl-C or `kill` stops it
gracefully — LEDs off, face neutral, servo centered, torque off.

`phrase_announcer.rb` picks a fixed phrase at random and speaks it
every 30s via `stackchan say --gain 0.175` (tuned by ear: the library default
0.05 is inaudible over room noise, 0.3 overdrives the 1W speaker).

Run both in the background and stop them together when done:

```bash
ruby tools/ambient_demo.rb >> /tmp/stackchan-picoruby-debug/ambient_demo.log 2>&1 &
ruby tools/phrase_announcer.rb >> /tmp/stackchan-picoruby-debug/phrase_announcer.log 2>&1 &
# later:
kill %1 %2
```

## Capabilities

| Subsystem | State | Notes |
|---|---|---|
| Faces (Neutral, Smile, Joy, Surprised, Sad, Angry) | yes | photo-derived geometry |
| Closed face | yes | torque-off idle indicator, not an emotion |
| Eye-blink animation | yes | eye-only redraw |
| WS2812 LED ring (12 px) | yes | solid, blink, breathing, off, per side |
| Servo control (yaw, pitch) | yes | normalized YL/YR/PU protocol, BLE calibration CLI |
| BLE control (Nordic UART Service) | yes | dRuby over BLE for commands, replies, touch and audio, 20 ms link loop |
| Speaker (AW88298 over I2S) | yes | mu-law audio sent from macOS as dRuby calls over BLE |
| Microphone | no | planned |
| IMU (BMI270 + BMM150) | no | planned |
| 3-zone head touch (Si12T) | yes | on-device face + LED pulse per tap, polled by the controller over dRuby |
| WiFi, HTTP, MQTT, WebSocket | no | gems available, wiring pending |
| Camera (GC0308) | no | deferred |
| NFC | no | deferred |

## Known issues

- The picoruby task has about 2 KB of its 8 KB stack left after startup.
  Drawing a face takes it to about 900 B: the ILI9342 primitives call
  `SPI#write` and `GPIO#write` through `mrb_funcall` down into the ESP-IDF SPI
  driver, and the reading varies by an interrupt frame (about 144 B). The
  acceptance floor is 512 B, room for a few interrupt frames. One raise and
  rescue takes about 1.8 KB, so an error that reaches one of the
  `rescue => e` handlers (dispatcher, touch poll, periodic handlers, a dRuby
  handler) can overflow the task. Raising `PICORB_TASK_STACK_SIZE` is the
  remedy; it is a firmware change. (#22)
- Discovery on the Mac takes about 10 s of the 15 s connect budget
  (`Central::CONNECT_TIMEOUT_MS`), so a reconnect can come back `busy` (exit 8)
  when discovery runs out before both CCCDs are found. (#19)
- The robot's GATT table ends with Service Changed, but whether that stops
  the Mac from reusing an old table has not been tried on the robot; until it
  has, `sudo pkill bluetoothd` after a table change. (#19)
- `rake ios:run` (and so `ios:all`) stops at `open -a Simulator` and never
  installs or launches the app.
- There is no retry path: `StackChan::Controller::Central` raises `TimeoutError` on an ACK
  timeout and the CLI command fails rather than the frame being resent once.
  This is a gap in the code, not an observed symptom; it has no effect until a
  frame is actually dropped.
- A client that hangs up mid-call is dropped, not fatal: the daemon's sockets
  carry `SO_NOSIGPIPE` (inherited from the listening socket), so the write to
  the gone peer fails with EPIPE and the dRuby server logs
  `DRb reply not delivered` and keeps accepting. The PicoRuby VM still cannot
  trap SIGPIPE itself (`Signal.list` carries no `PIPE`), so this relies on
  the socket layer. `rake pc:up` checks the port by asking the kernel who is
  listening, not by connecting.

## Audio path

macOS synthesizes speech with `say`, converts 8 kHz mono PCM to G.711 mu-law,
and sends it to the robot as dRuby calls over BLE.

The PC side calls `audio_begin(N)` (N = mu-law byte count), sends the bytes with
`audio_chunk` in 2048-byte calls, and calls `audio_play`, which reserves the
playback and returns. The robot plays the buffer after it has written the
reply, on its next link-loop tick. The PC waits `N / 8` ms plus 1 s, then
asks `audio_done` every 500 ms until it answers true, for at most
`3300 + N × 6 / 5` ms clamped to 30-180 s.

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
sit at that floor, close to the BLE round trip.

Numbers drift 15-25% between sessions; only compare runs from the same
session. `ROUNDS=8 tools/face_profile.zsh` produces the table.

| face | seconds |
|---|---|
| neutral | 0.16 |
| surprised | 0.16 |
| angry | 0.17 |
| smile | 0.18 |
| sad | 0.18 |
| joy | 0.21 |
| `led` (floor) | 0.18 |

Drawing cost follows primitive count; `picoruby-ili9342` issues the address
window, RAMWR and pixel stream from C, one call per shape. Neither pixel
count nor `SPI#write` count explains it.

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
4.0+, Bundler, and for the QEMU gate in front of every flash
`brew install libgcrypt glib pixman sdl2 libslirp`. Building and controlling
the device fetches its build trees on demand via `bundle exec rake
vendor:setup` (see "Code layout" above) rather than requiring hand-placed
sibling clones.

## Dependencies

Everything below is fetched on demand — no hand-placed sibling clones needed.
Repo/ref pins are the single source of truth for what a build actually runs;
this table exists so that fact doesn't have to be re-derived from Rakefiles
and build_configs each time.

| Repo | Role | Ref and sha live in |
|---|---|---|
| [bash0C7/R2P2-ESP32](https://github.com/bash0C7/R2P2-ESP32) | ESP32 device firmware build tree | `Rakefile` (`R2P2_ESP32_REPO`/`R2P2_ESP32_REF`), sha in `acceptance/lock.yml` |
| [bash0C7/R2P2-darwin](https://github.com/bash0C7/R2P2-darwin) | Apple platform: Mac PicoRuby VM, iOS / watchOS app builds | `Rakefile` (`R2P2_DARWIN_REPO`/`R2P2_DARWIN_REF`), sha in `acceptance/lock.yml` |
| [bash0C7/picoruby](https://github.com/bash0C7/picoruby) | PicoRuby itself, device side | R2P2-ESP32's `components/picoruby-esp32/picoruby` submodule pin |
| [bash0C7/picoruby](https://github.com/bash0C7/picoruby) | PicoRuby itself, Apple side (BLE + mbedtls + io-console + machine darwin ports) | R2P2-darwin's own `rake setup`, sha in `acceptance/lock.yml` |
| [bash0C7/picoruby-ili9342](https://github.com/bash0C7/picoruby-ili9342) | LCD driver, drawing primitives in C | `build_config/esp32-stackchan.rb` |
| [bash0C7/picoruby-py32-io-expander](https://github.com/bash0C7/picoruby-py32-io-expander) | PY32 I/O expander driver | same build_config |
| [bash0C7/picoruby-scservo](https://github.com/bash0C7/picoruby-scservo) | Servo driver | same build_config |
| [bash0C7/suppify](https://github.com/bash0C7/suppify) | Turns the AOT kernels into one mrbgem | `aot/suppify.pin` (`rake aot:setup`) |
| [matz/spinel](https://github.com/matz/spinel) | Ruby-to-C compiler behind the AOT kernels | suppify's `spinel.pin` |
| [bash0C7/picoruby-multicore](https://github.com/bash0C7/picoruby-multicore) | Runs a kernel on core 1 | `aot/multicore.pin` |

The WS2812, Si12T, AW88298 and dRuby-over-BLE gems are mrbgems in this
repo's `mrbgems/` bundled into `app.mrb` at compile time. The BLE frame
protocol gem (`mrbgems/picoruby-stackchan-protocol`, `FrameParser` /
`FrameCodec` / `FrameText`) is also in this repo, but is instead a gem dir
in `build_config/esp32-stackchan.rb`.

### Staying reproducible

Two of those pins can be satisfied on one disk and nowhere else. A submodule sha
becomes fetchable only when someone pushes a branch containing it, and committing
the pointer says nothing about whether that happened; a gem `branch:` disappears
when its pull request is merged with "delete branch". Either one leaves a tree
that builds here forever and stops a fresh clone dead.

`tools/check_deps_pushed.sh` asks both questions, counting only URLs whose host is
github.com — the clones on this machine sit under `~/dev/src/github.com/...`, so a
remote naming another directory on this disk spells the string while proving
nothing. It walks every pin, including the ones inside picoruby, and resolves the
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
`.github/workflows/deps.yml` clones the firmware tree from nothing on every push to
main, on every pull request, weekly and on demand, running the whole script,
which catches a ref that rots while nobody is looking.

`.github/workflows/firmware.yml` answers the larger question the dependency
check cannot: it builds the firmware in `espressif/idf:v5.4.2` from a fresh
clone, boots it under the QEMU gate and runs both suites, so "it works on
another machine" is measured rather than assumed. It does not flash and there
is no CoreS3 on a runner, so the bench is still the only thing that can say
whether the robot moves. A full esp-idf build is tens of minutes, so it runs
weekly and on demand rather than per push.

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
- `R2P2_BUILD_CONFIG` names an external picoruby build config in place of
  `build_config/xtensa-esp-picoruby.rb`, `R2P2_GEM_DIRS` adds gem dirs to the
  default config, and `R2P2_EXTRA_SRCS` adds C sources to the IDF component.
  The default config carries `picoruby-ble` and `picoruby-i2s`, whose ESP32
  ports the component compiles.
- Points its `components/picoruby-esp32/picoruby` submodule at the picoruby
  fork's firmware line below.

### [picoruby fork](https://github.com/bash0C7/picoruby)

BLE support (`mrbgems/picoruby-ble/`), on two lines:

- The firmware line (the R2P2-ESP32 submodule pin) — the ESP32 (NimBLE) peripheral port, on
  the lineage before the rebase that upstream PR
  [#427](https://github.com/picoruby/picoruby/pull/427) carries, and
  `picoruby-i2s`, with a commit on top that lets a peripheral drop its
  central.
- The Apple line (what R2P2-darwin fetches) — the macOS (CoreBluetooth) central/peripheral port used by
  `pc/stackchan-pico`'s BLE central and `vendor/R2P2-darwin`. The central
  role can receive a GAP disconnect but cannot initiate one (this port has
  no such API) — `StackChan::Controller::Central#disconnect` in
  `mrbgems/picoruby-stackchan-controller` is therefore a local-state-only
  no-op. An ACK timeout on a live link does not drop the link; the robot
  frees it after `release_after` (15 s in `apps/robot/app.rb`) without
  traffic.

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
