# Notifier 2.0 device verification handoff (2026-05-19)

## Status: host code done, on-device verification pending

Notifier 2.0 multi-command dispatch refactor (`:notify` / `:servo` /
`:raw` 3-kind BLE command bus) is host-side complete. All 71 host
tests pass. **Nothing has run through real BLE against a real
CoreS3.** This is the "実機で動かす" gap the next session needs to
close.

## What's shipped (this session)

- **Phase B Task 11/12** (ble-client side, `pc/stackchan-ble-client`)
  - `SendBuilder#head` + `FrameCodec.encode_head` for `<Y:..,P:..,T:..>` / `<Y:..,V:..>`
  - `stackchan-ble-control servo --yaw N --pitch M [--time N --velocity N]`
- **Phase B Task 13 → SUPERSEDED** — replaced by notifier 2.0 refactor
- **Notifier 2.0** (`pc/stackchan-notifier`, version bumped 0.1.0 → 2.0.0)
  - Tuple shape `[:cmd, Symbol, Hash]` (was 7-element positional)
  - Worker dispatches per-kind via handler registry (`NotifyHandler` /
    `ServoHandler` / `RawHandler`)
  - Per-kind latest-wins burst coalescing (drain_latest_per_kind)
  - `stackchan-notify --face NAME` drives face + LED + matched servo
    motion via `NotifyMotionTable`; `--silent` suppresses motion
  - 2 new CLIs: `stackchan-servo`, `stackchan-raw`
  - 71 host tests, 0 failures

## Spec / Plan (read these first next session)

- Spec: `docs/superpowers/specs/2026-05-19-notifier-multi-command-dispatch-design.md`
- Plan: `docs/superpowers/plans/2026-05-19-notifier-multi-command-dispatch.md`
- Phase B plan (Task 14-16 remaining): `docs/superpowers/plans/2026-05-19-phase-b-servo.md`

## What's NOT verified (next session scope)

### A. Notifier 2.0 device smoke (~30-45 min)

Daemon needs to actually connect to CoreS3 over BLE and dispatch each
kind. Each test below assumes device is powered, advertising, in BLE
range, and the cold-boot servo init succeeded (see
`/tmp/stackchan-picoruby-debug/boot-final-5puts.log` for the known-good
shape).

Setup:
```bash
cd pc/stackchan-notifier
bundle exec exe/stackchan-notifier-daemon &
# wait for "BLE connected" log line
```

Smoke matrix:

| # | Command | Expected device behavior |
|---|---|---|
| A1 | `bundle exec exe/stackchan-notify --face joy` | face=joy, head tilts up (pitch 600), LED off |
| A2 | `bundle exec exe/stackchan-notify --face sad --left_led red,blink` | face=sad, head down (pitch 280), left LED red blink |
| A3 | `bundle exec exe/stackchan-notify --face joy --silent` | face=joy, head DOES NOT move (still at A2's pitch 280) |
| A4 | `bundle exec exe/stackchan-notify --face neutral --duration 3` | face=neutral, head level (pitch 450), restores to neutral 3s later |
| A5 | `bundle exec exe/stackchan-servo --yaw 1000 --pitch 450 --time 500` | head pans right over 500ms |
| A6 | `bundle exec exe/stackchan-servo --yaw -1000 --pitch 450 --time 500` | head pans left |
| A7 | `bundle exec exe/stackchan-servo --yaw 0 --pitch 800` | head looks up (max) |
| A8 | `bundle exec exe/stackchan-raw --frame '<F:2>'` | face=joy (raw F:2 = joy index) |
| A9 | Rapid burst: `for i in 1 2 3 4 5; do bundle exec exe/stackchan-notify --face joy --silent; done` | Daemon should coalesce to 1 notify dispatch (check daemon log) |

Things that could break and what to look for:
- `Errno::ENOENT` on socket → daemon not running / socket path mismatch
- `BLE connected` never appears → device not advertising or wrong device name (export `BLE_DEVICE_NAME`)
- Frame arrives but device doesn't respond → check `bin/capture-with-pty` boot log for runtime errors in `application.rb` Dispatcher
- Servo motion missing on notify --face → `NotifyMotionTable` lookup didn't fire — check `params[:silent]` is false in Daemon log
- `--silent` not honored → handler skip logic broken
- Restore tuple doesn't fire → `@restore_thread` killed prematurely or Thread.new dispatch failed

### B. Phase B Task 14 — servo-verify skill + bin (~1 hour)

See `docs/superpowers/plans/2026-05-19-phase-b-servo.md` Task 14:

- Create `.claude/skills/stackchan-device-servo-verify/SKILL.md`
- Create `pc/stackchan-ble-client/exe/servo-verify` (uses
  `StackchanBleClient::Client` directly, NOT the notifier daemon)
- Add `Client#raw_send_and_capture_detail(frame, timeout:)` for the
  `<Y_actual:N,P_actual:M>` detail frame parsing
- 5-target tolerance test (center / right / left / down / up, ±8 unit
  tolerance)

This is separate from notifier 2.0 — it's the regression-test path for
servo accuracy independent of the daemon.

### C. Phase B Task 15 — HITL checklist (human-driven, 15-30 min)

After A and B both pass, walk through `docs/superpowers/plans/2026-05-19-phase-b-servo.md`
Task 15 with the device in view. Visual confirmation of motion
smoothness, range, no juddering, etc. Memory entry at the end captures
the lock-in.

### D. Phase B Task 16 — Final review (~30 min subagent)

Final code-reviewer over the entire Phase B branch range (Tasks 1-15).
Per Phase A discipline.

## Recovery if device is not in a known-good state

The device needs to be running the production `application.rb` that
includes the 5-puts PY32 init region (see memory entry
`project_py32_init_puts_required`). If cold boot crashes:

1. `/stackchan-device-cold-recovery` (wipe + redeploy + reset)
2. If that fails: `/stackchan-device-full-rebuild` (build_flash + wipe + redeploy)
3. If THAT fails: read `docs/superpowers/handoff-2026-05-19-phase-b-task10-cold-boot-crash.md`
   for the bisect approach we used last time

## Files / commits to be aware of

Notifier 2.0 implementation commits (16 total, all on main, base
`3512ee79` → head `3c9f9dc`):

```
git log --oneline 3512ee79..3c9f9dc -- pc/stackchan-notifier/
```

Memory entries added or relevant:
- `feedback_plan_assumes_nonexistent_structure` (this session)
- `project_notifier_keepalive_boundary` (prior — partially superseded
  by 2.0; the keep-alive part still holds, the "hook lazy reconnect"
  part is replaced by the always-on daemon model)

## Open questions for next session

1. Should `NotifyMotionTable` numbers be tuned by HITL before merging
   anywhere, or are the spec defaults good enough for first verify?
2. Does the existing `application.rb` Dispatcher route the
   `<Y_actual:..,P_actual:..>` detail frame back over BLE NUS as a
   notification, or is that still TODO firmware-side? (Task 14
   assumes yes — verify before depending on it)
3. After A pass, do we want a one-shot `stackchan-device-notifier-smoke`
   skill that runs the matrix automatically? Optional polish.
