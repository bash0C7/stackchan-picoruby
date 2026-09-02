# HANDOFF

Where the work stands and what comes next. **Current state only.**

This file is rewritten in place, never appended to. It carries no history: a
reader arriving cold has no reference point for what a past state was, so
"previously" and "as of <date>" do not belong here. Durable knowledge does not
belong here either — see "Where things are written" at the bottom.

## Now

The robot works end to end: cold boot, BLE link, faces, blink, LEDs, servos,
head touch, and mu-law audio playback.

| Piece | Revision |
|---|---|
| `stackchan-picoruby` | `main`, in sync with origin |
| firmware tree `vendor/R2P2-ESP32` | `stackchan-integration` @ `a5312fb` |
| picoruby submodule under it | `bash0C7/picoruby` `stackchan-integration` @ `7258676` |
| LCD driver gem | `bash0C7/picoruby-ili9342` @ `25e29b4` |

The CoreS3 is flashed from exactly those revisions, with `app/application.rb`
compiled into `/home/app.mrb` in the littlefs storage partition. Every revision
above is pushed, so this state is reproducible from a fresh clone.

Tests are green: picotest device 194 / pc 79 / shared 28 / led 39 / si12t 22 /
aw88298 14, plus the CRuby host
suites (`rake test:host`, macOS only because of `plutil`).

## Next

Two C gems wait for a firmware build:

1. `picoruby-aw88298`: add
   `conf.gem github: 'bash0C7/stackchan-picoruby', path: 'mrbgems/picoruby-aw88298'`
   to R2P2-ESP32's `build_config/xtensa-esp-picoruby.rb`. Until then the device
   build lacks `require 'aw88298'`.
2. `picoruby-ili9342` branch `claude/c-drawing-primitives` (drawing primitives
   in C): merge into `stackchan-integration` or point the build_config at it.

Then `r2p2:setup`, `build_flash`, redeploy the app, and measure with
`ROUNDS=8 tools/face_profile.zsh` against the table in the README.

Subproject C, BLE reliability — the three defects listed under "Known issues"
in the README. In rough order of how often they bite: no retry on an ACK
timeout, the ~45 s first `<A:done>` after a long idle, and `Daemon#stop` never
reaching its reply.

Face redraw latency is **not** on the list. Two ways to cut it are written up in
the README under "Latency", with measurements and costs;
the decision is to leave both alone for now.

## Where things are written

Nothing that outlives the current task should be recorded in this file.

- `README.md` — what the robot is and does, how to set it up and run it,
  capabilities, known issues, and the latency measurements with the remaining
  headroom
- `CLAUDE.md` — how to work in this repo: build and deploy flow, the device
  skills, and the pitfalls worth knowing before touching hardware
- this file — only the two sections above
