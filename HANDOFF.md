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

The robot is powered off and carries the firmware of the committed acceptance
report in `acceptance/results/`. That report's verdict is `fail`: every step
through the operator's questions passed, and it stopped at `torque off` because
the Mac daemon froze.

Since that run, without the robot:

- Every command, reply and head touch goes over dRuby over BLE; the text
  frames are gone from the controller, and the robot's first NUS pair answers
  only the direct audio route. The design is
  `docs/superpowers/specs/2026-10-10-druby-single-route-design.md`.
- Audio has two routes, the direct one (default) and a dRuby one
  (`say --drb`), so they can be timed against each other on the robot.
- The robot's GATT table ends with Service Changed.
- The servo driver keeps why its last read failed and the status byte of its
  last good reply, and the robot's front reports both (`remote servo_health`).
- The daemon freeze and the daemon dying when a client hangs up are both
  closed in the Mac VM, which is rebuilt and running under launchd. The
  running daemon still has the controller source it loaded at start;
  `rake pc:up` loads the current one.
- The picoruby the Mac VM is built from moved forward; the controller follows
  its GATT notification layout.
- `build_config/esp32-stackchan.rb` fetches the driver gems from each repo's
  default branch, and the lock pins a newer servo driver, so the next
  `acceptance:deploy` flashes.

`rake test` and the CRuby host tests pass. The iOS and watchOS apps build for
the Simulator and, started with `-StackchanBatch "actions"`, reach
`[batch] end`. The robot's app and gems load in QEMU (`r2p2:qemu_check`).
None of the above has met the robot.

`rake test` runs `rigor:check` first, a host-side type analysis that fails on
any diagnostic absent from `rigor.baseline.json`. It needs `rake vendor:setup`
to have run, and installs its own gemset into `vendor/rigor-tool` on first use.
`docs/rigor.md` is the reference. `deps.yml` runs on every push; `firmware.yml`
runs weekly and on demand, so trigger it with `gh workflow run firmware.yml`
after changing anything it covers.

## Next

### A. Approve the Xcode MCP server, then run the Simulator skill through it

`claude mcp list` shows the project's `xcode` server as pending approval, and
only the owner can approve it (`/mcp`). Until then the skill
`stackchan-apple-simulator` has never run through Xcode MCP; the same steps
are verified with `xcodebuild` and `xcrun simctl`. Once approved, run the
skill for `ios` and `watchos` and correct it against what the tools actually
take and return. `bash0C7/R2P2-darwin`'s CLAUDE.md has the working notes for
those tools.

Left unverified next to this: R2P2-darwin's own watchOS build_config still
lists `hal-io-darwin`, which no longer satisfies mruby's HAL provider contract
at the picoruby this project pins, so its watchOS build should fail the same
way this repository's did. That is R2P2-darwin's and the picoruby fork's to fix.

### B. One acceptance run with the robot on

`acceptance:deploy` (the one flash), then `acceptance:check` run once by the
owner in a TTY, and the report committed.

That run is the first time these meet the robot:

- A real BLE link through the rebuilt Mac VM: scan, discovery, both CCCDs,
  notifications. It has only reached `busy` with the robot off.
- Every action over dRuby, the one-second `touches` poll as keepalive, and
  `touch listen` fed by that poll.
- The GATT table with Service Changed: QEMU never registers the table, so
  whether NimBLE accepts it is first seen at boot on the robot. Whether it
  stops the Mac from reusing an old table is a separate observation: connect
  without `sudo pkill bluetoothd` after the flash and see if both dRuby
  handles resolve.
- The dRuby audio route: the robot buffers the whole clip from 2048-byte
  calls and plays it from its link loop after replying.
- `chat` against the real sidecar.

The report carries what the owner needs for the open decisions: `say direct`
and `say drb` with the stack reading after each, `connect ms`, the `servo
health` line, and the per-action timings over dRuby.

Why the daemon froze, what closed it, and what is still unexplained (three
scheduler ticks that ran off the VM thread; the kernel source for this macOS
is not published) are in the vault: `review/2026-10-01-daemon-freeze/`,
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
