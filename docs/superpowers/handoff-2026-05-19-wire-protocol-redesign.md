# Wire-protocol redesign + notifier 2.0 smoke (2026-05-19)

## Status: smoke A1-A9 dispatched on real device, no client-side errors. Visual HITL still pending.

The frame-delimited BLE wire protocol is shipped end-to-end. Notifier 2.0
no longer raises `unknown ack byte/frame` during A1-A9. The remaining
verification is **visual** (face renders, servo motion direction/range,
LED behavior) which only a human looking at the device can confirm.

## What's shipped this session

Plan: `docs/superpowers/plans/2026-05-19-frame-delimited-wire-protocol.md`

Commits (newest first, on `main`, base `d66a20f`):

```
091fca4 fix(ble-client): reset @last_detail_frame at start of send_frame
d122557 feat(ble-client): drain device detail frame after servo ACK
2ce7f78 chore(ble-client): clean up parse_ack test names + dedupe
f530add feat(ble-client): parse_ack accepts frame string
f90ed2a feat(protocol): device-side frame queue (Array) replaces byte ACK queue
92f1642 feat(protocol): dispatcher emits complete frames per write
```

### Device side

`mrbgems/picoruby-stackchan-protocol/examples/application.rb`:

- Dispatcher writes complete newline-terminated frame strings per call:
  `".\n"` / `"?\n"` for ACK, `"<Y_actual:N,P_actual:M>\n"` or
  `"<ERROR:servo_timeout,axis:both>\n"` for the trailing detail frame.
- `@ack_queue` (concatenated `String`) → `@notify_queue` (Array of frame
  strings).
- `flush_one_ack` → `flush_one_frame`: one `Array#shift` +
  `push_read_value(@tx_handle, frame)` + `notify(@tx_handle)` per call.
  Each invocation of can-send-now produces **exactly one ATT
  notification per complete frame** (multi-byte 1 notify confirmed via
  `att_server_notify(con, handle, data, size)` in
  `picoruby-ble/ports/esp32/ble_peripheral.c:65-68`).
- HCI_EVENT_DISCONNECTION_COMPLETE branch clears `@notify_queue = []` so
  a reconnect cannot see leftover bytes from the previous session.

### Mac side

`pc/stackchan-ble-client/lib/stackchan_ble_client/`:

- `frame_codec.rb` `parse_ack(frame)`: reads `frame[0, 1]` (back-compat
  with bare 1-char byte). Error message renamed to `unknown ack frame`.
- `client.rb` `send_frame`: after consuming the ACK, drains a trailing
  detail frame if the outgoing frame contained a Y/P/V/T axis key
  (mirrors the device's `servo_present` check). Drained value stashed in
  `@last_detail_frame` for the future Phase B Task 14 detail-read API.
  `@last_detail_frame` is reset at the top of every `send_frame` and at
  `connect`, so it always reflects the most recent single frame.

### Tests

- `mrbgems/picoruby-stackchan-protocol`: 16 tests, 18 assertions (added
  `test_dispatcher_frame_contract.rb` with 4 cases pinning the new write
  contract).
- `pc/stackchan-ble-client`: 68 tests, 138 assertions (added drain tests
  for servo / non-servo paths).
- `pc/stackchan-notifier`: 71 tests, 157 assertions (no regressions —
  worker / handler are transparent to the wire change).

## Smoke A1-A9 result (handoff Section A from the prior session)

Daemon log range `/tmp/stackchan-picoruby-debug/notifier-daemon.log`
2026-05-19T20:05-20:06. A1 through A9 dispatched cleanly. One reconnect
(`Peripheral not connected` at 20:06:20) during the A9 5x burst —
expected 60s peri.start window expiry, daemon `pending_retry` absorbed
it without an exception. **No `unknown ack frame` exception, no worker
thread termination, no `parse_ack` raise.** This was the root failure
mode the redesign was supposed to fix; it is fixed.

What is **not** verified by claude alone:

- Visual face render correctness per command (joy / sad / neutral /
  surprised / angry / smile)
- Servo direction sense (StackChan's-left vs StackChan's-right on
  positive yaw — the wire chart in
  `feedback_stackchan_wire_format.md` says ble-client absorbs the
  reversal already; need eyes on device to confirm)
- LED blink mode visible (red blink on left for A2)
- A3 silent: no head motion when face changes
- A4 duration: 3s later head + face restore to neutral

→ Human needs to walk the matrix once with eyes on the StackChan and
sign off. See `Open question 1` below.

## What's NOT verified (next session scope)

### A. Visual HITL pass (~15 min, human only)

Walk the A1-A9 matrix from the prior handoff
`docs/superpowers/handoff-2026-05-19-notifier-2.0-device-verify-pending.md`
section A and visually confirm each command lands the expected face /
LED / servo state. The daemon side is already known to dispatch cleanly,
so the only failures to look for are visual / mechanical.

Skill setup: `/stackchan-device-iterate` is the easy way to redeploy
between attempts if needed; the daemon is launched manually (see
prior handoff Section A Setup block).

### B. Phase B Task 14 — servo-verify skill + bin

`docs/superpowers/plans/2026-05-19-phase-b-servo.md` Task 14.

Wire-protocol implications for Task 14:

- The plan as written assumes a `Client#raw_send_and_capture_detail`
  that does ACK + detail read. The drain path is now implemented but it
  **discards the detail value into `@last_detail_frame`**. Task 14 can
  either: (a) add a public `read_last_detail` accessor on `Client` and
  call it after each servo send; or (b) re-implement
  `raw_send_and_capture_detail` as `raw_send + read_last_detail` — same
  semantics, less surface area.
- Frame strings on the wire now end with `\n`, which Task 14's parser
  for `<Y_actual:N,P_actual:M>\n` already handles since the plan
  expects newline-terminated frames.
- Detail frames over MTU 23 are a theoretical risk; today's smoke
  matrix passed (32-byte `<ERROR:servo_timeout,axis:both>\n` notifies
  worked), so MTU negotiation completes fast enough in practice. If
  Task 14 starts hitting truncation, see "Open question 2" below.

### C. Phase B Task 15 — HITL checklist

Same as before. After A passes, walk the HITL checklist in
`docs/superpowers/plans/2026-05-19-phase-b-servo.md` Task 15. Mostly
visual confirmation of motion smoothness, range, no juddering.

### D. Phase B Task 16 — Final review

After A+B+C all pass, code-reviewer subagent over the entire Phase B
branch range (Tasks 1-15 + the wire-protocol redesign).

## Open questions

1. **NotifyMotionTable defaults**: should `pc/stackchan-notifier/lib/stackchan_notifier/notify_motion_table.rb`
   numbers be tuned by HITL before merge, or are the spec defaults
   already adequate? Prior handoff question, still open.

2. **MTU pre-flight check**: today's smoke matrix passed without
   explicit MTU negotiation guard. Final code-reviewer flagged that the
   largest detail frame (32 bytes) could be truncated to 20 bytes if
   the ATT MTU exchange has not completed before the first `flush_one_frame`.
   Mitigation options before Task 14:
   - Add a `sleep 0.1` in `Client#connect` after subscribe
   - Add a notify-side MTU check in the device app (skip flush until
     `att_server_get_mtu(con_handle) >= 32`)
   - Wait for a Task 14 truncation bug to surface and address then

3. **Phase B Task 14 plan in `docs/superpowers/plans/2026-05-19-phase-b-servo.md`**:
   the plan's example code at line 954 still uses the old `ACK_BYTE` /
   `ERROR_BYTE` constants. Update the plan in-place when Task 14
   actually starts, OR write a Task 14 v2 plan that builds on the new
   wire contract.

## Recovery / iteration shortcuts

- Code edit → iterate: `/stackchan-device-iterate` (upload-app + reset
  + capture + analyze, ~50s)
- Daemon: see prior handoff Section A Setup block, or:
  ```bash
  rm -f /tmp/stackchan-notifier-501.sock /tmp/stackchan-picoruby-debug/notifier-daemon.log
  BLE_DEVICE_NAME=StackChan-PicoRuby nohup bundle exec exe/stackchan-notifier-daemon --log-level debug > /tmp/stackchan-picoruby-debug/notifier-daemon.log 2>&1 &
  disown
  ```
- Boot panic: `/stackchan-device-boot-verify` (auto-analyzes Guru
  Meditation if found)
- Bad autostart: `/stackchan-device-cold-recovery` (wipe + redeploy +
  reset, ~30s)

## Memory entries worth adding (next session)

- `project_frame_delimited_wire_protocol_complete` — record the
  redesign so future plans don't ask "should ACK be 1 byte?" again.
- `feedback_drain_trailing_detail_when_servo_present` — wire-protocol
  rule: servo frames return TWO BLE notifications (ACK + detail);
  client.send_frame drains both. Anyone touching `send_frame` should
  preserve the drain.
