# HANDOFF

Where the work stands and what comes next. **Current state only.**

Rewritten in place, never appended to. It carries no history: a reader arriving
cold has no reference point for a past state, so "previously" and "as of
<date>" do not belong here. Durable knowledge does not belong here either —
README.md is what the robot is and does, CLAUDE.md is how to work on it, and
specs, plans and reviews live in the Obsidian vault under
`02_dev_docs/stackchan-picoruby/`.

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

- The daemon freeze and the daemon dying when a client hangs up are both
  closed in the Mac VM, which is rebuilt and running under launchd.
- The picoruby the Mac VM is built from moved forward; the controller follows
  its GATT notification layout.
- `build_config/esp32-stackchan.rb` fetches the driver gems from each repo's
  default branch. The commits are the same, but build_config is a firmware
  input, so the next `acceptance:deploy` flashes.

`rake test` passes. The CRuby host tests pass except
`platform_trees_test#test_r2p2_darwin_names_no_stackchan` (#21).

`rake test` runs `rigor:check` first, a host-side type analysis that fails on
any diagnostic absent from `rigor.baseline.json`. It needs `rake vendor:setup`
to have run, and installs its own gemset into `vendor/rigor-tool` on first use.
`docs/rigor.md` is the reference. `deps.yml` runs on every push; `firmware.yml`
runs weekly and on demand, so trigger it with `gh workflow run firmware.yml`
after changing anything it covers.

## Next

### 1. One acceptance run with the robot on

`acceptance:deploy` (the one flash), then `acceptance:check` run once by the
owner in a TTY, and the report committed.

That run is the first time these meet the robot:

- A real BLE link through the rebuilt Mac VM: scan, discovery, both CCCDs,
  notifications, dRuby. Read against the port's source it is consistent with
  the controller; it has only reached `busy` with the robot off.
- `chat` against the real sidecar.

Why the daemon froze, what closed it, and what is still unexplained (three
scheduler ticks that ran off the VM thread; the kernel source for this macOS
is not published) are in the vault: `review/2026-10-01-daemon-freeze/`,
`plans/2026-10-03-daemon-tick-thread.md` and
`review/2026-10-10-pr11-closing-notes.md`.

### 2. Open issues

- #20: every app action still sends text frames; only the CLI's `remote` uses
  dRuby.
- #19: the dRuby unification itself, with audio measured before it may keep a
  direct route. It also covers Service Changed.
- #21: build the `-StackchanBatch` apps in the Simulator; certificates are
  revoked; `devicectl_udid` and `platform_trees_test` are open.
- #22: host tests that imitate the robot, dRuby timings, audio distortion, the
  stack headroom and `PICORB_TASK_STACK_SIZE`, `FIRMWARE_INPUTS` taking all of
  `aot/`, the revert guard having no test, and a pitch position read that
  failed three times in a row once. For the last, the ESP32 receive path is
  ruled out by source (vault `review/2026-10-03-pitch-read-pos/`); what is left
  is the pitch servo being silent for about 300 ms right after a move starts,
  which only the status byte the driver discards or a bus voltage measurement
  can settle.
- #23: move `docs/superpowers/` to the vault.
- Older and still open: #4, #5, #6 and #8.
- The holes closed in the Mac VM are also in mruby's POSIX task HAL and in
  upstream picoruby-socket / picoruby-drb. That is upstream PR material.

### 3. Adopting upstream picoruby for the firmware

The firmware's picoruby line, rebased onto upstream master, overflows the 8 KB
picoruby task stack during its own startup and boot-loops on the CoreS3. The
line in use leaves the picoruby task only a few hundred bytes at startup, so
the rebased one needs just a little more depth to cross the line. Raising
`PICORB_TASK_STACK_SIZE` is a design decision, not a tweak (CLAUDE.md).

The NimBLE ESP32 port itself is not waiting on this; it is what the device
runs. What the boot loop blocks is adopting that port as upstream carries it.
Its plan is in the vault under `02_dev_docs/picoruby-ble-esp32-port/plans/`.

### 4. What the dependency guard does not reach

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
