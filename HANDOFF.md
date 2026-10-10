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
covers `torque`, `face`, `led`, `servo`, `selftest`, `calibrate`, the
`remote` verb, `servo health`, `say`, `chat` against the real sidecar, and
the robot releasing a quiet central with the next action reconnecting. The
head was not touched within the 30 s of that run.

The robot gem on `main` differs from the app that report ran: its GATT
constants are renamed (`DRB_*`), same values. The robot does not carry that
app yet, so `acceptance:check` refuses until `acceptance:app` has sent it
(A).

An iPhone drives the robot: it connects in about 2.3 s and `raw`, the face
and LED buttons, the head moves, `subtitle`, `selftest` and `speak_audio`
all answer over dRuby. An Apple Watch does not yet (B).

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

### A. Send the app and run the check

With the CoreS3 on USB (`rake r2p2:boards` marks it): `acceptance:app`,
then one `acceptance:check` in tmux with the owner answering the questions.
The commits after the report are local until that check passes.

### B. The Apple Watch against the robot

The watch app installs and starts, and its first run against the robot went:
no advertiser for about 30 s, then a connection that ended in
`dRuby pair not found`, then no advertiser on every later try. The same
controller code connects from the iPhone.

- The first scan may have sat behind the watch's Bluetooth permission
  dialog; the owner has not said whether one appeared.
- `dRuby pair not found` lists what discovery found
  (`discovered services=N characteristics=…`), so the next run tells an
  empty or cut-short discovery from a table the watch remembered from an
  older robot. That run has not happened: the watch must be unlocked, on the
  wrist and near the Mac for `watchos:device:build` to see it.
- The later failures have one cause: after the failed connect the watch
  still held the link, so the robot was not advertising. Nothing drops such
  a link. picoruby-ble's central has no disconnect, and the robot releases
  a central only once it has seen dRuby traffic from it, because the ESP32
  port hands the robot no event when a central connects
  (`ports/esp32/ble.c`, `BLE_GAP_EVENT_CONNECT` enqueues nothing for a
  peripheral). A central that connects and never subscribes holds the robot
  until it goes away by itself. Closing that needs the port to deliver a
  connection event, which is a firmware change.

`rake ios:device:run` and `watchos:device:run` pick a Simulator on this
Xcode (bash0C7/R2P2-darwin issue 21). Until that is fixed, install and
launch with `xcrun devicectl device install app --device <UDID> <app>` and
`xcrun devicectl device process launch --console --terminate-existing
--device <UDID> -- <bundle id> -StackchanBatch "<lines>"`; `rake
acceptance:darwin` goes through the rake tasks and so cannot pass yet. Its
watchOS batch also asks for `selftest`, an action the watch app does not
have.

### C. Things found on the way, not yet acted on

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

- #19: done from the Mac and the iPhone; what is left of it is the Watch
  (B).
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
