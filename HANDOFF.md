# HANDOFF

Where the work stands and what comes next. **Current state only.**

Rewritten in place, never appended to. It carries no history: a reader arriving
cold has no reference point for a past state, so "previously" and "as of
<date>" do not belong here. Durable knowledge does not belong here either —
README.md is what the robot is and does, CLAUDE.md is how to work on it, specs
and plans live in `docs/superpowers/`, and reviews and evidence live in the
Obsidian vault under `02_dev_docs/stackchan-picoruby/review/`.

Branch names and commit ids are not written here. What a build runs is read
from where a machine reads it: `acceptance/lock.yml` for every sha, `Rakefile`
and `build_config/esp32-stackchan.rb` for the refs the build follows.

## Now

Everything is on `main`. The robot works, and every subsystem it has has been
driven on the hardware: cold boot, BLE link, faces, LEDs, servos on both axes,
head touch, audio, and selftest. Servo absolute positioning — the point of the
whole thing — lands where it is told.

Everything between a controller and the robot is dRuby over BLE, audio
included. The robot's GATT table holds GAP, one service with the dRuby pair,
and Service Changed. The design is
`docs/superpowers/specs/2026-10-10-druby-single-route-design.md`.

The latest report in `acceptance/results/` has verdict `pass`: one check run
start to finish in a TTY, from the Mac, with the owner at the robot. It
covers `torque`, `face`, `led`, `servo`, `selftest`, head touch,
`calibrate`, the `remote` verb, `servo health`, `say`, `chat` against the
real sidecar, and the robot releasing a quiet central with the next action
reconnecting. The robot carries the app that report ran.

An iPhone drives the robot: it connects in about 2.3 s and `raw`, the face
and LED buttons, the head moves, `subtitle`, `selftest` and `speak_audio`
all answer over dRuby. An Apple Watch drives it too: worn, with the app in
front, `connect`, `顔をかえる`, `LEDを光らせる` and `ぐるっと` all answer over
dRuby.

`rake test` and the CRuby host tests pass. The iOS and watchOS apps start in
the Simulators and answer `status` through the bridge
(`/stackchan-apple-simulator`).

`rake test` runs `rigor:check` first, a host-side type analysis that fails on
any diagnostic absent from `rigor.baseline.json`. It needs `rake vendor:setup`
to have run, and installs its own gemset into `vendor/rigor-tool` on first use.
`docs/rigor.md` is the reference. `deps.yml` runs on every push; `firmware.yml`
runs weekly and on demand, so trigger it with `gh workflow run firmware.yml`
after changing anything it covers.

## Next

### A. The Apple apps from the command line

The apps work in the hand. What does not work is driving them unattended.

- A watch app started with `-StackchanBatch` while nobody keeps the watch
  awake finds no advertiser: a scan whose timeout is 15 s takes 34 s to
  60 s there, and a later batch line can stay silent for minutes. The same
  app, worn and tapped, connects at once. The scan's wait counts passes of
  the VM's idle loop, not a clock, so an app the watch is not running in
  front neither scans nor times out on time.
- A watch that has seen an older robot answers discovery from the table it
  remembered (`dRuby pair not found; discovered services=1
  characteristics=6e400002,6e400003` against a robot that holds
  `6e400004` and `6e400005`). Restarting the watch makes it forget.
- After a failed connect the central still holds the link, so the robot is
  not advertising and every later try finds no advertiser. Nothing drops
  such a link. picoruby-ble's central has no disconnect, and the robot
  releases a central only once it has seen dRuby traffic from it, because
  the ESP32 port hands the robot no event when a central connects
  (`ports/esp32/ble.c`, `BLE_GAP_EVENT_CONNECT` enqueues nothing for a
  peripheral). Closing that needs the port to deliver a connection event,
  which is a firmware change. Until then, end the app to free the robot:
  `xcrun devicectl device info processes --device <UDID>` for the pid,
  then `xcrun devicectl device process terminate --device <UDID> --pid
  <pid> --kill`.
- The Mac sees the watch only while it is unlocked, awake and near; it
  drops to `unavailable` within seconds otherwise.

`rake ios:device:run` and `watchos:device:run` pick a Simulator on this
Xcode (bash0C7/R2P2-darwin issue 21), and `watchos:device:build` stops
unless the watch is reachable at that moment. Until that is fixed: build
with `xcodebuild -project apps/watchos/WatchStackchan.xcodeproj -scheme
WatchStackchan -destination 'generic/platform=watchOS' -derivedDataPath
vendor/R2P2-darwin/build/watchos-stackchan-app-device ARCHS=arm64_32
-allowProvisioningUpdates build` after `rake watchos:device:lib
watchos:gen`, then install and launch with `xcrun devicectl device install
app --device <UDID> <app>` and `xcrun devicectl device process launch
--console --terminate-existing --device <UDID> -- <bundle id>
-StackchanBatch "<lines>"`; without `-StackchanBatch` the same launch
attaches the console to an app a person taps. `rake acceptance:darwin`
goes through the rake tasks and so cannot pass yet. Its watchOS batch also
asks for `selftest`, an action the watch app does not have.

### B. Things found on the way, not yet acted on

- `DRbBle::Responder#reply` calls the front with `send`. For a method the
  front defines that is direct, but a `bot.remote` handler is reached through
  `method_missing`, so on the robot it would run inside a nested VM and cost
  about 3 KB of the 8 KB task stack. `apps/robot/app.rb` declares no such
  handler.
- Frames as text (`<F:0>`) are how the controller's `Session` hands a
  command to `Central`, which parses them back into the Hash that dRuby
  carries. The CLI's `raw` verb needs that format; the rest could build the
  Hash directly.
- R2P2-darwin's own watchOS build_config lists `hal-io-darwin`, which does
  not satisfy mruby's HAL provider contract at the picoruby this project
  pins. That is R2P2-darwin's and the picoruby fork's to fix.

What is known about the Mac daemon freezing is in the vault:
`review/2026-10-01-daemon-freeze/`, `plans/2026-10-03-daemon-tick-thread.md`
and `review/2026-10-10-pr11-closing-notes.md`.

### Open issues

- #22: what is left needs the robot or a decision. A pitch position read can
  fail several times in a row; the ESP32 receive path is ruled out by source
  (vault `review/2026-10-03-pitch-read-pos/`), and `servo health` tells a
  silent servo from a bad reply when it happens. The stack headroom and
  `PICORB_TASK_STACK_SIZE` are a design decision (CLAUDE.md). Discovery time
  is recorded as `connect ms`.
- #24: LCD touch.
- The holes closed in the Mac VM are also in mruby's POSIX task HAL and in
  upstream picoruby-socket / picoruby-drb. That is upstream PR material.

### Adopting upstream picoruby for the firmware

The firmware's picoruby line, rebased onto upstream master, overflows the 8 KB
picoruby task stack during its own startup and boot-loops on the CoreS3. The
line in use leaves the picoruby task only a few hundred bytes at startup, so
the rebased one needs just a little more depth to cross the line. Raising
`PICORB_TASK_STACK_SIZE` is a design decision, not a tweak (CLAUDE.md).

The NimBLE ESP32 port itself is not waiting on this; it is what the device
runs. What the boot loop blocks is adopting that port as upstream carries it.
Its plan is in the vault under `02_dev_docs/picoruby-ble-esp32-port/plans/`.

### What the dependency guard does not reach

`--pins-only` checks pins and nothing else, so a rotted gem ref or an edited
vendored tree passes at push time and is caught only by a full run.
`reachable_from_github` answers from remote-tracking refs before fetching, so a
branch force-pushed away reads as published until CI's fresh clone disagrees.
And `STACKCHAN_DEPS_GUARD=off` is one string away for whoever finds the guard
inconvenient.

Branch protection is handled separately, and would cover default branches
only. The refs this build depends on in the two forks are long-lived
integration branches, which protection would not cover, so those stay
detection-only.

## Known and deliberately left alone

- The device tasks expect esp-idf at `~/esp/esp-idf` unless `ESP_IDF_EXPORT`
  says otherwise. The version is pinned where a machine reads it — the image
  tag in the firmware workflow — and the python venv is found by version rather
  than named.
