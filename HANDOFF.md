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

- The daemon freeze and the daemon dying when a client hangs up are both
  closed in the Mac VM, which is rebuilt and running under launchd.
- The picoruby the Mac VM is built from moved forward; the controller follows
  its GATT notification layout.
- `build_config/esp32-stackchan.rb` fetches the driver gems from each repo's
  default branch. The commits are the same, but build_config is a firmware
  input, so the next `acceptance:deploy` flashes.

`rake test` and the CRuby host tests pass, and `deps.yml` and `firmware.yml`
are green on `main`. The iOS and watchOS apps build for the Simulator and,
started with `-StackchanBatch "actions"`, reach `[batch] end`; both also link
for a device unsigned (`<platform>:device:check`).

`rake test` runs `rigor:check` first, a host-side type analysis that fails on
any diagnostic absent from `rigor.baseline.json`. It needs `rake vendor:setup`
to have run, and installs its own gemset into `vendor/rigor-tool` on first use.
`docs/rigor.md` is the reference. `deps.yml` runs on every push; `firmware.yml`
runs weekly and on demand, so trigger it with `gh workflow run firmware.yml`
after changing anything it covers.

## Next

The owner has asked for the first four in this order, in one flow, without the
robot. The acceptance run comes after them.

### A. Write the layering down in CLAUDE.md

CLAUDE.md lists where files live but never states the principle: only this
repository knows StackChan; picoruby, R2P2-ESP32, R2P2-darwin and the driver
gems serve any project and must not learn about it; a build_config or app here
conforms to the contract the platform sets. One or two sentences at the head of
the 構成 section. It replaces a rule and a grep test that only recorded a past
mistake (both deleted).

### B. Run the Simulator check through Xcode MCP

The skill `stackchan-apple-simulator` and `.mcp.json` are in place but have not
run through Xcode MCP: the session that wrote them had no `xcode` server (it
loads at session start; `sudo xcrun mcp-server enable` must have been run once).
The same steps were verified with `xcrun simctl` instead. Run the skill for
`ios` and `watchos`, correct it against what the tools actually take and
return, and only then call it verified. `bash0C7/R2P2-darwin`'s CLAUDE.md has
the working notes for those tools.

Left unverified next to this: R2P2-darwin's own watchOS build_config still
lists `hal-io-darwin`, which no longer satisfies mruby's HAL provider contract
at the picoruby this project pins, so its watchOS build should fail the same
way this repository's did. That is R2P2-darwin's and the picoruby fork's to fix.

### C. Issue #22

Its body lists what is left: dRuby timings for more than servo, `stackchan
remote` exiting 0 on a refusal, `FIRMWARE_INPUTS` taking all of `aot/`, the
host test that imitates the robot (`FakeOps`), the revert guard having no test,
discovery time after the VM refresh, the pitch read, the stack headroom.

### D. Issue #19

Move every app action, keepalive, calibration read and head touch onto dRuby
over BLE; measure audio before deciding whether it keeps a direct route; add
Service Changed. The robot side changes only in gems bundled into `app.mrb`.

### E. One acceptance run with the robot on

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

### Open issues

- #19: every app action still sends text frames and only the CLI's `remote`
  uses dRuby; unify the route on dRuby over BLE, with audio measured before it
  may keep a direct route. It also covers Service Changed.
- #22: host tests that imitate the robot, dRuby timings, the
  stack headroom and `PICORB_TASK_STACK_SIZE`, `FIRMWARE_INPUTS` taking all of
  `aot/`, the revert guard having no test, and a pitch position read that
  failed three times in a row once. For the last, the ESP32 receive path is
  ruled out by source (vault `review/2026-10-03-pitch-read-pos/`); what is left
  is the pitch servo being silent for about 300 ms right after a move starts,
  which only the status byte the driver discards or a bus voltage measurement
  can settle.
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
