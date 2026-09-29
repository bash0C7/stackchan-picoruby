# HANDOFF

Where the work stands and what comes next. **Current state only.**

Rewritten in place, never appended to. It carries no history: a reader arriving
cold has no reference point for a past state, so "previously" and "as of
<date>" do not belong here. Durable knowledge does not belong here either —
README.md is what the robot is and does, CLAUDE.md is how to work on it, and
specs, plans and reviews live in the Obsidian vault under
`02_dev_docs/stackchan-picoruby/`.

## Now

The robot works, and every subsystem it has has been driven on the hardware:
cold boot, BLE link, faces, LEDs, servos on both axes, head touch, audio, and
selftest. Servo absolute positioning — the point of the whole thing — lands
where it is told: commanding yaw-left 50 with pitch-up 30 reads back
`<YL_actual:50,PU_actual:29>`, and yaw-right 40 with pitch-up 10 reads back
`<YR_actual:39,PU_actual:9>`.

| Piece | Revision |
|---|---|
| `stackchan-picoruby` | `main` @ `0a65507`, pushed |
| firmware tree `vendor/R2P2-ESP32` | `c-primitives-verified` @ `2f18720` |
| picoruby submodule under it | `7258676` |
| LCD driver gem | `bash0C7/picoruby-ili9342` `main` @ `01a1a02` |
| speaker gem | `mrbgems/picoruby-aw88298` here, fetched from `main` by the build_config |

The device reports App version `2f18720`, so it is running this tree.

Tests pass: 476 picotest across device, pc, shared, aot, drb-ble and the three driver gems,
with no failures, crashes or skips, plus the CRuby host tests, where ten cases
are omitted on machines without `plutil`. Both workflows are green on the tip
of `main`.

`rake test` runs `rigor:check` first, a host-side type analysis that fails
on any diagnostic absent from `rigor.baseline.json`. It needs `rake vendor:setup`
to have run, and installs its own gemset into `vendor/rigor-tool` on first use.
Seventeen diagnostics are frozen in the snapshot; eight of them are false
positives from rigor 0.3.7 and the rest are stated invariants the code does not
declare. `docs/rigor.md` is the reference. `deps.yml` runs on every push; `firmware.yml` runs weekly and on
demand, so trigger it with `gh workflow run firmware.yml` after changing
anything it covers.

## In flight: one branch, one PR, one firmware on the robot

Everything below `main` is on `claude/ecstatic-allen-s6qki1` (PR #11 → `main`).
It carries, in commit order: dRuby over BLE, the AOT kernels (`ulaw_decode`,
`glyph16`), picoruby-multicore on core 1, the deterministic QEMU boot gate, and
DSL steps 1–5 (protocol gem folded in, robot engine + `apps/robot/app.rb`,
controller engine + `apps/mac/app.rb`, `apps/ios` + `apps/watchos`, the
firmware gem list in `build_config/esp32-stackchan.rb`). It also carries the
device tooling that picks the CoreS3 by USB serial, and the trial that puts one
firmware on the robot once (`trial:deploy`), sends the app on its own
(`trial:app`) and checks the board without writing flash (`trial:check`).

`trial/lock.yml` pins the one firmware:

| repo | branch | sha |
|---|---|---|
| R2P2-ESP32 | `claude/external-build-config` | `9716605` |
| picoruby (fork, under R2P2-ESP32) | `claude/ble-peripheral-disconnect` | `9c4636a` |
| R2P2-darwin | `claude/external-app` | `7a02219` |
| picoruby-ili9342 | `claude/aot-glyph16` | `6adc482` |
| picoruby-py32-io-expander | `claude/simplify` | `8f8b3d3` |
| picoruby-scservo | `claude/simplify` | `1e3a18b` |
| suppify | `claude/string-arg-length` | `a5449a3` |

The robot runs it. Report `trial/results/20260929-093450` (uncommitted, verdict
`fail`) holds a deploy that passed every step and a check that stops at the
last move of the hand-off (Next 1). The deploy checked the pins before and after the build, passed the
QEMU gate, flashed once, sent the app separately (`DONE_ACK ok`), read flash
identity `0.2.21-39-g9716605` with storage at `0x410000`, and captured a boot
log through `HCI WORKING — advertising` with no fault.

On the Mac, `rake test` and `test:host` pass except
`platform_trees_test#test_r2p2_darwin_names_no_stackchan`: the locked
R2P2-darwin `7a02219` names stackchan-picoruby in its README, README_jp and
`docs/superpowers/`, which belongs to that branch. rigor runs at 0.4.0.

With `BLE_FAKE=1` / `STUB=1` the daemon answers `status`, `chat` (stub reply)
and `calibrate` (JSON from five piped Enters), and a second daemon under
`NS=handoff` comes up beside the first.

The iOS and watchOS apps build with `rake ios:lib ios:gen ios:build` /
`watchos:…` at the locked darwin pin. Launched on a Simulator with
`-StackchanTrial "actions"`, they reach `[trial] end`. `rake ios:run` stops at
`open -a Simulator`, which this Mac cannot find, so the launch was
`xcrun simctl launch --console-pty`.

## Next

### 1. Check the controller fixes on the robot, then finish the report

Report `trial/results/20260929-093450` (uncommitted, verdict `fail`) holds the
one deploy and a check that passed every step up to `hand-off Mac A → Mac B →
Mac A`, where Mac A's last `face neutral` ended in `ACK timeout for "<F:0>"`.
The check reached `pc:up` on its first try once `sudo pkill bluetoothd` had
cleared the Mac's cached GATT table (the robot publishes no Service Changed).

Two controller defects explain it; each is fixed with a host test that failed
first (`rake test` green, rigor `0 new, 0 fixed`, nothing pushed):

- `1e057cd`: a reconnect whose 15 s scan ran out mid-discovery came back with
  a target and a connection but no descriptors; `subscribe_tx` dropped the
  missing CCCDs and the next frame went out with notifications off. bluetoothd
  shows the good reconnect enabling notifications and the failed one never
  doing so. Both CCCDs are now required, so a short discovery answers busy
  (exit 8) and the next action reconnects.
- `794dbda`: `Task.new` blocks run with `self` as `main`, so the daemon's tick
  task died on its first `tick` (no keepalive, no hold-over to quiet, no idle
  drain; `release seen: no`) and the shutdown task never stopped DRb.

Discovery on the Mac takes about 10 s after connecting, which leaves little of
the 15 s budget. Both picoruby-ble sessions read the darwin port as stepping
once per 1 s heartbeat; that is inferred from code, not measured. It is in the
shared status table in the vault
(`02_dev_docs/picoruby-ble-esp32-port/notes/2026-09-29-stackchan-alignment-status.md`),
and the evidence for this failure is under
`02_dev_docs/stackchan-picoruby/review/2026-09-29-handoff-ack-timeout/`.

1. `bundle exec rake trial:check STAMP=20260929-093450 FROM=pc:up` (needs the
   owner's go; no flash, no app upload, the controller is loaded from source).
   Expect keepalives and `hold over` in `/tmp/stackchan-pico/daemon.log` and
   `release seen: yes`. A discovery that overruns now shows as exit 8 rather
   than an ACK timeout; that is the darwin port's pace, not a regression. A
   pass here does not prove `1e057cd` — its host test does.
2. With a person at the robot: `rake trial:touch STAMP=20260929-093450`, then
   `rake trial:answer STAMP=20260929-093450`. The face and LEDs reacting to a
   head touch have been seen by eye; the report still needs the CLI's
   `touch zone=N`.
3. `rake trial:darwin` needs `DEVELOPMENT_TEAM` and a valid certificate for
   the iPhone and Watch builds; every Apple Development certificate on this Mac
   is revoked.
4. The report must read `verdict: pass`; commit it.

What the check verifies by machine:

- flash identity and boot
- face / LED / servo detail / `remote` / `say` over more than two multicore
  chunks, and their timings
- the task stack left after every robot handler kind (stops below 1,024 B)
- `selftest` detail, a head touch, `calibrate` JSON
- `chat` against the STUB sidecar
- the robot releasing an idle Mac, and the Mac reconnecting on its next action
- a hand-off between two Mac daemons: the second is refused with exit 8 while
  the first holds the robot

`c.hold 10_000` / `bot.release_after 15_000` are first guesses; the check's
reconnect timings decide them. With keepalives running, the robot releases an
idle Mac about 22 s after its last action, against the check's 30 s quiet wait.

The firmware stays on the robot for all of it. A fault found on the robot is
reproduced under QEMU or on the host and fixed there; putting a fix on the
robot is the owner's call.

Open alongside it:

- **Service Changed.** Adding 0x1801 / Service Changed to `peripheral.rb`
  would stop the Mac caching the GATT table. It is an app change, so it needs
  no firmware flash.
- **Darwin port.** The Mac VM stays at picoruby `97479c96`. The newest
  `port-darwin` is `7681c4f4` (unpushed): it fixes the layout mismatch and the
  build under Xcode 27, and moving to it means `radio.rb` reads notifications
  through the gem's `gatt_event_int16` / `gatt_event_value`. Rebuilding the VM
  at `97479c96` on this Mac is expected to fail on the missing Swift header.
- **Where the ESP32 fixes land.** The status table proposes syncing PR #427's
  ESP32 fixes into the robot's picoruby lineage after this trial.
- **Speaker distortion.** TTS is scaled to 0.05 before μ-law and the amp runs
  at full volume; comparing `stackchan say --gain 0.02 / 0.05 / 0.15` by ear
  decides whether the amp or the μ-law step is at fault.

### 2. After `verdict: pass`

Merge PR #11. Then bring each related repo's branch to its `main` (the sha in
the table), point the Rakefile's `R2P2_ESP32_REF` / `R2P2_DARWIN_REF` and the
build config's gem refs back at `main`, and archive `bash0C7/picoruby-stackchan-protocol` on GitHub (nothing
here refers to it).

### 3. The daemon has no defence against a client hanging up

Any client that hangs up mid-call can kill the daemon: its PicoRuby VM cannot
trap SIGPIPE (`Signal.list` carries no `PIPE` and every `Signal.trap` form
raises `SystemStackError`), so a peer gone while the daemon writes to it takes
the process down, and launchd restarts it. Closing that means `SO_NOSIGPIPE`
or an ignored SIGPIPE in picoruby's socket layer, which is upstream work
rather than a change here.

### 4. The lineage that will not boot

`c-primitives-verified` and `stackchan-integration` in the R2P2-ESP32 fork
differ by exactly one line, the picoruby submodule pointer: `7258676`, which
boots, against `568b4b88`, the lineage rebased onto upstream master, which
overflows the 8 KB picoruby task stack during its own startup and boot-loops.
`7258676` itself starts its picoruby task with 248 B of the 8 KB left, so the rebased lineage
needs only a little more startup depth to cross the line.
Switching is a one-line bump once that is resolved. Land shared changes on
both. The NimBLE ESP32 port itself is not waiting on this. It is what the device
runs — the vendored tree carries `nimble_owner.c`, there is no btstack
component, and the sdkconfig fragment is `bt_nimble` — and every verb drives it
end to end. What the boot loop blocks is adopting that port rebased
onto upstream master. Its plan is in the vault under
`02_dev_docs/picoruby-ble-esp32-port/plans/`.

### 5. What the dependency guard does not reach

`--pins-only` checks pins and nothing else, so a rotted gem ref or an edited
vendored tree passes at push time and is caught only by a full run.
`reachable_from_github` answers from remote-tracking refs before fetching, so a
branch force-pushed away reads as published until CI's fresh clone disagrees.
And `STACKCHAN_DEPS_GUARD=off` is one string away for whoever finds the guard
inconvenient.

Branch protection is handled separately, and would cover main and master only.
The refs this build depends on are long-lived integration branches and tags,
which protection would not cover, so those stay detection-only.

## Known and deliberately left alone

- The device tasks expect esp-idf at `~/esp/esp-idf` unless `ESP_IDF_EXPORT`
  says otherwise. The version is pinned where a machine reads it —
  `espressif/idf:v5.4.2` in the firmware workflow — and the python venv is
  found by version rather than named.
