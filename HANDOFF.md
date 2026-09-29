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
`fail`) holds a deploy that passed every step and a check that stops at
`pc:up`. The deploy checked the pins before and after the build, passed the
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

### 1. Let the Mac see the robot's new GATT table, then check

`pc:up` finds the robot, connects, and finishes GATT discovery (`Stopped by
state: TC_IDLE`). It then fails with `dRuby pair not found`
(`central.rb:191`): the Mac's list has NUS RX / TX but not `6e400004` /
`6e400005`. The code rules out both ends as the cause:

- **Robot:** `parse_att_db` in the ESP32 port either registers the whole
  Ruby-built table with NimBLE or makes `BLE.new` raise `BLE init failed`. The
  boot log shows `BLE_hci_power_control(1): started=1` and then advertising.
- **Mac:** the darwin port discovers with `nil` filters, and every
  characteristic it gets passes the decoder's range check.

The hypothesis is that CoreBluetooth is serving, from its cache, the table
this robot had under the `main` firmware (NUS RX / TX only). Three things
support it:

- The robot publishes no Service Changed (no 0x1801) and keeps the same public
  address across firmware.
- The vault records this trap
  (`handoff-2026-05-21-implementation-start.md`).
- The picoruby-ble-esp32-port session has measured it: only
  `sudo pkill bluetoothd` clears it; toggling Bluetooth does not.

It is unconfirmed until step 2 below.

1. At the Mac (a person, needs the password): `sudo pkill bluetoothd`. This
   has been done; the Mac has not reconnected since.
   - First, fix the guard that `trial:check` and `trial:app` run. It stops when
     HEAD differs from the deploy's `7c677b8`, and HEAD has since moved by
     documentation commits only, so step 2 would stop before touching anything.
   - The guard should compare what the board runs: the lock's `firmware:`
     digest, plus a digest of the app source together with the gem sources
     bundled into it. HEAD is the wrong thing to compare.
   - Fix it host-tested first, then do step 2.
2. `bundle exec rake trial:check STAMP=20260929-093450 FROM=pc:up`. If
   `dRuby pair not found` persists, the cache was not the cause; read the
   robot side before anything touches it again.
3. With a person at the robot: `rake trial:touch STAMP=20260929-093450`, then
   `rake trial:answer STAMP=20260929-093450`.
4. `rake trial:darwin` needs `DEVELOPMENT_TEAM` and a valid certificate for
   the iPhone and Watch builds; every Apple Development certificate on this Mac
   is revoked. `watchos:device:lib` also fails; its log at
   `/tmp/stackchan-picoruby-debug/watchos-device-check.log` has not been read.
5. The report must read `verdict: pass`; commit it.

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
reconnect timings decide them. `trial:darwin` then checks each app's
trial-mode console (`Connected; RX value_handle bound`, `OK face=joy`, the
selftest detail) and the hand-off Mac → iPhone → Watch → Mac.

The firmware stays on the robot for all of it. A fault found on the robot is
reproduced under QEMU or on the host and fixed there; putting a fix on the
robot is the owner's call.

The robot's picoruby (`9c4636a4`) and the PR #427 lineage the
picoruby-ble-esp32-port session develops have diverged. Both sessions keep the
picoruby-ble state in one table in the vault:
`02_dev_docs/picoruby-ble-esp32-port/notes/2026-09-29-stackchan-alignment-status.md`.
It records the branches and shas, the changes only one side has, the files
likely to conflict, and the owner's open decisions.

- **Where the ESP32 fixes land.** The table proposes syncing PR #427's ESP32
  fixes into the stackchan lineage.
- **Service Changed.** Adding 0x1801 / Service Changed to `peripheral.rb` would
  stop the Mac caching the table. It is an app change, so it needs no firmware
  flash.
- **R2P2-darwin's picoruby stays at `97479c96`.** On `port-darwin`, `ee10fd96`
  broke Mac discovery: its decoder read the new GATT event layout while its
  Swift still wrote the old one. `7036c76a` fixes that. Moving to it also means
  `radio.rb:38-41` in the controller must read notifications at 8 / 10 / 12
  instead of 4 / 6 / 8.

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
