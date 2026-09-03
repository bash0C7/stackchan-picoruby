# HANDOFF

Where the work stands and what comes next. **Current state only.**

This file is rewritten in place, never appended to. It carries no history: a
reader arriving cold has no reference point for what a past state was, so
"previously" and "as of <date>" do not belong here. Durable knowledge does not
belong here either — see "Where things are written" at the bottom.

## Now

The robot works end to end with the drawing primitives and the mu-law decode in
C: cold boot, BLE link, faces, blink, LEDs, servos, head touch, and audio
playback.

| Piece | Revision |
|---|---|
| `stackchan-picoruby` | `main` @ `3a46e2c`, pushed, both workflows green on it |
| firmware tree `vendor/R2P2-ESP32` | `c-primitives-verified` @ `2f18720` |
| picoruby submodule under it | `7258676` (on GitHub as `stackchan-integration-verified`) |
| LCD driver gem | `bash0C7/picoruby-ili9342` `main` @ `01a1a02` |
| speaker gem | `mrbgems/picoruby-aw88298` here, fetched from `main` by the build_config |

Face redraw is 0.16-0.21 s against a 0.18 s BLE floor, down from 0.42-0.67 s;
the README has the table. Speech is 8 kHz mu-law at gain 0.05 — nothing clips
digitally at any gain, so audible break-up is the 1 W speaker being overdriven.

Tests: picotest device 194 / pc 79 / shared 28 / led 39 / si12t 22 / aw88298 14,
skip 0, plus six CRuby host test files, 53 tests (ten omitted where plutil is
absent).

Two workflows answer two questions. `deps.yml` runs `tools/check_deps_pushed.sh`
from an empty runner on every push and weekly, resolving all 19 nested submodule
pins from nothing; that is the one judge local state cannot fool. `firmware.yml`
builds in `espressif/idf:v5.4.2` from a fresh clone, produces a 2.3 MB
`R2P2-ESP32.bin` with 45% of the app partition free, then rebuilds the host VM
and runs every suite. It runs weekly and on demand, **not per push**, so after
changing anything it covers, trigger it: `gh workflow run firmware.yml`.

Before a push, the Claude Code hook in `.claude/settings.json` runs the guard in
`--pins-only` mode and refuses a push whose pins would not survive, naming the
one at fault on stderr. `STACKCHAN_DEPS_GUARD=off` in front of the command
stands it down, which the push that publishes a pin needs.

## Next

### 1. The bench

Nothing here says whether the robot moves; neither workflow flashes, and there is
no CoreS3 on a runner. **No CoreS3 is attached to this Mac either** — there is no
`/dev/cu.usbmodem*`.

Nothing that goes into the firmware has moved: `vendor/R2P2-ESP32` is still
`2f18720` with its picoruby pin at `7258676`, `app/application.rb` and
`mrbgems/` are untouched, and `bin/mrbc` still resolves. So the device should
still match this tree and `/stackchan-device-iterate` is the right first step
rather than a rebuild — but "should" is inference, and the boot log is what
settles it.

On the Mac side, launchd holds both jobs: `com.bash0c7.stackchan-sidecar` is
running and `com.bash0c7.stackchan-daemon` is not, so `rake pc:up` comes before
any `stackchan` verb.

### 2. Subproject C, BLE reliability

The defects under "Known issues" in the README: no retry on an ACK timeout, the
~45 s first `<A:done>` after a long idle, and `Daemon#stop` never reaching its
reply. The daemon also died once with SIGPIPE right after a `selftest` and
launchd restarted it; seen once, so it is not in the README.

### 3. What the guard still does not reach

`--pins-only` checks pins and nothing else, so a rotted gem ref or an edited
vendored tree passes at push time and is caught only by a full run.
`reachable_from_github` answers from remote-tracking refs before fetching, so a
branch force-pushed away on GitHub reads as published until CI's fresh clone
disagrees. And `STACKCHAN_DEPS_GUARD=off` is one string away for whoever finds
the guard inconvenient.

Branch protection is being handled separately. It would be main and master only,
and the refs this build depends on are mostly long-lived integration branches
(`c-primitives-verified`, `port-darwin`, `stackchan-integration`) and tags, which
protection would not cover anyway. Those stay detection-only, which is what the
ref check already is.

## Known and deliberately left alone

- The device tasks expect esp-idf at `~/esp/esp-idf` unless `ESP_IDF_EXPORT` says
  otherwise. The version is pinned where a machine reads it —
  `espressif/idf:v5.4.2` in the firmware workflow — rather than only in prose,
  and the python venv is found by version instead of named.

## Standing arrangements

- The R2P2-ESP32 fork's two branches differ by exactly one thing, the picoruby
  submodule pointer: `c-primitives-verified` holds `7258676`, which boots;
  `stackchan-integration` (`c1c56d4`) holds `568b4b88`, the lineage rebased onto
  upstream master, which overflows the 8 KB picoruby task stack during its own
  startup — before any application runs — and boot-loops. Everything else is
  identical, so switching is a one-line bump once that is resolved. Keep it that
  way: land shared changes on both.
- PR #10 is a draft holding the pre-launchd daemon process-management work and
  the NimBLE port plan. Nothing about it has been reviewed; its own body says
  what to look at.
- Publishing a pin is itself a push, so the guard would block the one command
  that fixes it. Prefix that push with `STACKCHAN_DEPS_GUARD=off` and nothing
  else.

## Where things are written

Nothing that outlives the current task should be recorded in this file.

- `README.md` — what the robot is and does, how to set it up and run it,
  capabilities, known issues, the latency measurements, and how the guard works
- `CLAUDE.md` — how to work in this repo: build and deploy flow, the device
  skills, and the pitfalls worth knowing before touching hardware
- this file — only the sections above
