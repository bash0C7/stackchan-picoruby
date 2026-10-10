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

The robot carries the firmware and app of the latest report in
`acceptance/results/`: the deploy passed every step, including the boot with
Service Changed in the GATT table. That report's verdict is `fail`. Its check
ran without a TTY and reached, over a real BLE link, `torque on`, `face`,
`led` and `servo` through dRuby (connect took 2.5 s and 6.4 s on its two
runs), then stopped at `remote servo detail`. The cause was in the controller,
not the robot, and is fixed on `main`: `stackchan remote` called the robot's
front through `send`, which waits where the Mac's BLE notifications are never
collected (CLAUDE.md, the CRuby differences). The fix has not met the robot.

Right after that, the robot left the Mac: no ESP32 on the USB bus and no
StackChan advertiser. The last BLE connection before it succeeded. Nothing
here can tell a power-off from a pulled cable; it needs a person at the robot.

What is on `main` and has not met the robot beyond the steps above:

- Every command, reply and head touch goes over dRuby over BLE; the text
  frames are gone from the controller, and the robot's first NUS pair answers
  only the direct audio route. The design is
  `docs/superpowers/specs/2026-10-10-druby-single-route-design.md`.
- Audio has two routes, the direct one (default) and a dRuby one
  (`say --drb`), so they can be timed against each other on the robot.
- The servo driver keeps why its last read failed and the status byte of its
  last good reply, and the robot's front reports both (`remote servo_health`).
- The one-second `touches` poll as keepalive, and `touch listen` fed by it.

`rake test` and the CRuby host tests pass. The iOS and watchOS apps build and
start in the Simulator through Xcode MCP (`/stackchan-apple-simulator`) and
reach `[batch] end`.

`rake test` runs `rigor:check` first, a host-side type analysis that fails on
any diagnostic absent from `rigor.baseline.json`. It needs `rake vendor:setup`
to have run, and installs its own gemset into `vendor/rigor-tool` on first use.
`docs/rigor.md` is the reference. `deps.yml` runs on every push; `firmware.yml`
runs weekly and on demand, so trigger it with `gh workflow run firmware.yml`
after changing anything it covers.

## Next

### A. Get the robot back on USB, then one acceptance check

With the CoreS3 on USB and powered (`rake r2p2:boards` lists it): the owner
runs `acceptance:check` once in a TTY at the robot. No deploy is needed; only
the controller changed since the flash, and the check restarts the daemon
with the current source.

What that run meets for the first time:

- `stackchan remote` after the fix, and everything after it in the check:
  `servo health`, the timings over dRuby, `say` on both audio routes with the
  stack reading after each, `touch listen` fed by the poll, calibrate, release
  and reconnect, `chat` against the real sidecar.
- Whether Service Changed stops the Mac from reusing an old GATT table. The
  table registered and the robot connected; the Mac was not seen to need
  `sudo pkill bluetoothd` after this flash, which changed the table.

If the robot does not come back as a USB device with power applied, read the
boot log first (`/stackchan-device-boot-verify`); do not flash to find out.

### B. Things found on the way, not yet acted on

- `DRbBle::Responder#reply` calls the front with `send`. For a method the
  front defines that is direct, but a `bot.remote` handler is reached through
  `method_missing`, so on the robot it would run inside a nested VM and cost
  about 3 KB of the 8 KB task stack. `apps/robot/app.rb` declares no such
  handler today.
- The iOS and watchOS bridges call the controller from C (`App.__send__`), so
  every wait inside an action is the same kind of wait that hid the reply on
  the Mac. Whether their BLE events arrive anyway is unverified; it needs a
  phone or watch against the robot (`acceptance:darwin`).
- R2P2-darwin's own watchOS build_config still lists `hal-io-darwin`, which
  no longer satisfies mruby's HAL provider contract at the picoruby this
  project pins, so its watchOS build should fail the same way this
  repository's did. That is R2P2-darwin's and the picoruby fork's to fix.

Why the daemon froze in the previous report, what closed it, and what is
still unexplained are in the vault: `review/2026-10-01-daemon-freeze/`,
`plans/2026-10-03-daemon-tick-thread.md` and
`review/2026-10-10-pr11-closing-notes.md`.

### C. Decide the audio route

With the report's two `say` timings: if dRuby carries audio well enough, the
first NUS pair, `AudioReceiver` and the firmware's dependency on the frame
parser all go; if not, the direct route stays as the one stated exception.

### Open issues

- #19: implemented except the audio decision above; closes after the
  acceptance run confirms it on the robot.
- #22: what is left needs the robot or a decision. The pitch position read
  that failed three times in a row once: the ESP32 receive path is ruled out
  by source (vault `review/2026-10-03-pitch-read-pos/`), and `servo health`
  now tells a silent servo from a bad reply the next time it happens. The
  stack headroom and `PICORB_TASK_STACK_SIZE` are a design decision
  (CLAUDE.md). Discovery time is recorded as `connect ms`.
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
