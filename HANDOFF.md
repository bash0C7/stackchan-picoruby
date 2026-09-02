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
| `stackchan-picoruby` | branch `claude/picoruby-prompt-simplify-dmbyo6` (PR #9) |
| firmware tree `vendor/R2P2-ESP32` | `c-primitives-verified` @ `fae4d74` |
| picoruby submodule under it | `bash0C7/picoruby` `stackchan-integration` @ `7258676` |
| LCD driver gem | `bash0C7/picoruby-ili9342` `claude/c-drawing-primitives` @ `067d47f` (PR #1) |
| speaker gem | `mrbgems/picoruby-aw88298` in this repo, fetched by the build_config |

The CoreS3 is flashed from exactly those revisions, with `app/application.rb`
compiled into `/home/app.mrb` in the littlefs storage partition.

Confirmed on the device: cold boot reaches `HCI WORKING — advertising` with no
panic, the six faces the CLI exposes all draw, `say` plays through the C
decode, torque / servo / selftest answer with real positions, and the
`BLE_FAKE=1` path runs. Face redraw now sits at the BLE floor — the README
table has the numbers. The faces and the LEDs have been looked at, driven by
head touch, and render as they did before the primitives moved to C.

Tests are green: picotest device 194 / pc 79 / shared 28 / led 39 / si12t 22 /
aw88298 14, skip 0, plus the five CRuby host files (`rake test:host`, macOS
only because of `plutil`).

## Next

1. The R2P2-ESP32 fork's `stackchan-integration` carries `bd348c0`, which
   moves the picoruby submodule to the lineage rebased onto upstream master
   (`568b4b88`). **That lineage does not boot on this board.** The firmware
   builds and flashes cleanly, then the picoruby task overflows its 8 KB
   stack immediately after `main_task: Returned from app_main()` and the
   board reboots in a loop. Erasing the storage partition so `/home/app.mrb`
   does not exist changes nothing, so it is the lineage's own startup, not
   the application. `PICORB_TASK_STACK_SIZE` is `1024 * 8` on both lineages.
   Raising it would also move the budget the draw-path and BLE constraints
   are written against, so it is a decision, not a tweak. Until then the
   branch above is where the working build_config lives; `stackchan-integration`
   is untouched.
2. Subproject C, BLE reliability — the defects under "Known issues" in the
   README: no retry on an ACK timeout, the ~45 s first `<A:done>` after a long
   idle, and `Daemon#stop` never reaching its reply. The daemon also died once
   with SIGPIPE right after a `selftest` and launchd restarted it; that is not
   in the README because it has been seen once.

## Where things are written

Nothing that outlives the current task should be recorded in this file.

- `README.md` — what the robot is and does, how to set it up and run it,
  capabilities, known issues, and the latency measurements
- `CLAUDE.md` — how to work in this repo: build and deploy flow, the device
  skills, and the pitfalls worth knowing before touching hardware
- this file — only the two sections above
