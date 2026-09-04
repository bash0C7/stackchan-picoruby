# HANDOFF

Where the work stands and what comes next. **Current state only.**

This file is rewritten in place, never appended to. It carries no history: a
reader arriving cold has no reference point for what a past state was, so
"previously" and "as of <date>" do not belong here. Durable knowledge does not
belong here either — see "Where things are written" at the bottom.

## Now

The robot works end to end, and every subsystem it has has been driven on the
hardware: cold boot, BLE link, faces, LEDs, servos in both axes, head touch,
audio playback, and selftest. Servo absolute positioning — the point of the
whole thing — lands where it is told: `--yaw-left 50 --pitch-up 30` reads back
`<YL_actual:50,PU_actual:29>`, `--yaw-right 40 --pitch-up 10` reads back
`<YR_actual:39,PU_actual:9>`.

| Piece | Revision |
|---|---|
| `stackchan-picoruby` | `main`, the only branch, in sync with origin |
| firmware tree `vendor/R2P2-ESP32` | `c-primitives-verified` @ `2f18720` |
| picoruby submodule under it | `7258676` (on GitHub as `stackchan-integration-verified`) |
| LCD driver gem | `bash0C7/picoruby-ili9342` `main` @ `01a1a02` |
| speaker gem | `mrbgems/picoruby-aw88298` here, fetched from `main` by the build_config |

The device reports App version `2f18720`, matching the firmware tree.

Face redraw is 0.16-0.21 s against a 0.18 s BLE floor; the README has the
table. Speech is 8 kHz mu-law at gain 0.05 — nothing clips digitally at any
gain, so audible break-up is the 1 W speaker being overdriven.

Tests: picotest device 194 / pc 82 / shared 28 / led 39 / si12t 22 / aw88298
14 — 379, no failures, no crashes, no skips — plus six CRuby host test files,
53 tests (ten omitted where plutil is absent).

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

### 1. Subproject C, BLE reliability

- An ACK timeout is not retried. `ble_client.rb` raises `TimeoutError` and the
  CLI command fails; a dropped frame is never resent.
- `<A:done>` can take about 45 s on the first `say` after a long idle. This one
  is untested rather than doubtful: a `say` on a freshly booted, warm device
  answers in seconds, which is not the ten-hour-idle condition the entry
  describes. Recreating that condition is what would settle it.
- `Daemon#start` primes the sidecar between opening the drb port and announcing
  itself, so a sidecar connect that hangs freezes the daemon VM with the port
  already open and `rake pc:up` reports a listening daemon that will not answer
  status. Running `rake pc:up` again clears it. The code says "Known, not fixed
  here"; the README now says it too.
- A daemon SIGPIPE was seen once right after a `selftest`, with launchd
  restarting it. It did not recur.

### 2. What the guard still does not reach

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
- `r2p2:upload_appmrb` wipes storage before uploading, because `main_task.rb`
  loads `/home/app.mrb` unconditionally and this application never returns, so
  no shell exists to receive an upload and no keypress escapes it. `upload_mrb`
  (`DST=`) cannot do the same without destroying `app.mrb`, so a helper upload
  onto a device running the autostart payload still needs a wipe, the helper,
  and then `app.mrb` again.

## Standing arrangements

- The R2P2-ESP32 fork's two branches differ by exactly one thing, the picoruby
  submodule pointer: `c-primitives-verified` holds `7258676`, which boots;
  `stackchan-integration` (`c1c56d4`) holds `568b4b88`, the lineage rebased onto
  upstream master, which overflows the 8 KB picoruby task stack during its own
  startup — before any application runs — and boot-loops. Everything else is
  identical, so switching is a one-line bump once that is resolved. Keep it that
  way: land shared changes on both. This boot loop is also what stands between
  the NimBLE ESP32 port and its hardware E2E.
- Publishing a pin is itself a push, so the guard would block the one command
  that fixes it. Prefix that push with `STACKCHAN_DEPS_GUARD=off` and nothing
  else.

## Where things are written

Nothing that outlives the current task should be recorded in this file.

- `README.md` — what the robot is and does, how to set it up and run it,
  capabilities, known issues, the latency measurements, and how the guard works
- `CLAUDE.md` — how to work in this repo: build and deploy flow, the device
  skills, and the pitfalls worth knowing before touching hardware
- the Obsidian vault, `02_dev_docs/` — specs, plans and reviews, including the
  picoruby-ble ESP32 NimBLE port plan under `picoruby-ble-esp32-port/plans/`
- this file — only the sections above
