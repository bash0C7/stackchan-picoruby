# Frame-Delimited BLE Wire Protocol Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the byte-stream ACK queue on the device with a frame-queue so that each BLE notification carries exactly one complete frame, eliminating the "detail frame contaminates next ACK" bug and the stale-queue-across-reconnect bug.

**Architecture:** Device-side: `StackChanApp` keeps an Array-of-strings notify queue (was `String` byte-stream). Each `Dispatcher.write(frame_str)` call appends one element; each `request_can_send_now → flush_one_frame` flushes one whole frame via `push_read_value(tx_handle, frame) + notify(tx_handle)`, which `att_server_notify` sends as one ATT notification (multi-byte OK on ESP32 port, verified). On disconnect, the queue is cleared. Dispatcher writes complete newline-terminated frames: `".\n"` / `"?\n"` for ACK, `"<Y_actual:..,P_actual:..>\n"` or `"<ERROR:servo_timeout,axis:..>\n"` for detail. Mac-side client treats `@subscription.next_value` as returning one complete frame, parses the first byte as ACK status. Phase B Task 14 will gain a follow-up `read_next_frame` API for detail frames.

**Tech Stack:** PicoRuby on R2P2-ESP32 (BTstack vendored), Ruby 4.0 + CoreBluetoothMac on Mac, test-unit for host tests.

---

## File Structure

**Modify:**
- `mrbgems/picoruby-stackchan-protocol/examples/application.rb` — `Dispatcher#handle`, `StackChanApp#write`, `flush_one_ack` → `flush_one_frame`, `packet_callback` disconnect branch, heartbeat queue-check predicate
- `mrbgems/picoruby-stackchan-protocol/test/test_dispatcher_servo_red.rb` — Dispatcher write contract test (frame strings, not bytes)
- `mrbgems/picoruby-stackchan-protocol/test/fake_stdio.rb` — match new write contract (frames as array entries, not concatenated bytes)
- `pc/stackchan-ble-client/lib/stackchan_ble_client/frame_codec.rb` — `parse_ack` accepts frame string (first byte = status, optional trailing `\n`)
- `pc/stackchan-ble-client/test/test_frame_codec.rb` — update parse_ack assertions

**No change expected:**
- `pc/stackchan-notifier/**` — worker/handlers stay the same; downstream protocol change is transparent
- `mrbgems/picoruby-stackchan-protocol/lib/stackchan_protocol/frame_parser.rb` — RX path (host → device) unchanged
- `pc/stackchan-ble-client/lib/stackchan_ble_client/client.rb` — `send_frame` already reads one notification and passes it to `parse_ack`; the only change is that the value now contains 2+ bytes instead of 1, which `parse_ack` handles

**Reference only (verified, do not modify):**
- `mrbgems/picoruby-ble/src/mruby/ble.c:103-110` — `mrb_push_read_value` accepts any-length String
- `mrbgems/picoruby-ble/ports/esp32/ble_peripheral.c:65-68` — `att_server_notify(con, handle, data, size)` sends multi-byte payload

---

## Phase 1 — Host-testable Dispatcher write contract

### Task 1: Dispatcher emits whole frames, not single bytes

**Files:**
- Modify: `mrbgems/picoruby-stackchan-protocol/examples/application.rb:243-354` (Dispatcher class)
- Modify: `mrbgems/picoruby-stackchan-protocol/test/fake_stdio.rb`
- Modify: `mrbgems/picoruby-stackchan-protocol/test/test_dispatcher_servo_red.rb` (or whichever existing dispatcher test asserts on bytes — pick the file that has "ACK byte" assertions; if multiple, update all)

- [ ] **Step 1: Read current test_dispatcher_*.rb to find byte-level assertions**

Run: `grep -rn "ACK_BYTE\|\\.bytes\\|@history\\|write.*\\.[\"']\"" mrbgems/picoruby-stackchan-protocol/test/`

Identify the assertions that check `stdout.history == ["."]` or `stdout.last_byte == "."` style.

- [ ] **Step 2: Write the failing test in a new file** `mrbgems/picoruby-stackchan-protocol/test/test_dispatcher_frame_contract.rb`

```ruby
require_relative "test_helper"
require_relative "fake_stdio"

class TestDispatcherFrameContract < Test::Unit::TestCase
  def setup
    @stdout = FakeStdio.new
    @display = FakeDisplay.new
    @led = FakeLed.new
    @head = FakeHead.new(yaw_pos: 0, pitch_pos: 600)
    @dispatcher = StackchanApp::Dispatcher.new(
      display: @display, led: @led, stdout: @stdout, head: @head
    )
  end

  def test_face_frame_emits_one_ack_frame_with_newline
    @dispatcher.handle({ "F" => "2" })
    assert_equal [".\n"], @stdout.frames
  end

  def test_servo_frame_emits_ack_frame_then_detail_frame
    @dispatcher.handle({ "Y" => "0", "P" => "600", "T" => "250" })
    assert_equal [".\n", "<Y_actual:0,P_actual:600>\n"], @stdout.frames
  end

  def test_servo_timeout_emits_ack_then_error_detail_frame
    @head.fail_read = true
    @dispatcher.handle({ "Y" => "0", "P" => "600", "T" => "250" })
    assert_equal [".\n", "<ERROR:servo_timeout,axis:both>\n"], @stdout.frames
  end

  def test_bad_face_index_emits_error_ack_frame
    @dispatcher.handle({ "F" => "99" })
    assert_equal ["?\n"], @stdout.frames
  end
end
```

- [ ] **Step 3: Update `FakeStdio` to expose `#frames`**

Open `mrbgems/picoruby-stackchan-protocol/test/fake_stdio.rb`. Replace the body so each `#write(s)` appends to a `@frames` array (preserve `#history` if other tests still need it):

```ruby
class FakeStdio
  attr_reader :frames

  def initialize
    @frames = []
  end

  def write(s)
    @frames << s
  end

  # Back-compat for older tests that read history as concatenated bytes.
  def history
    @frames.join
  end
end
```

- [ ] **Step 4: Run new test to verify it fails**

Subagent (general-purpose, haiku): `cd mrbgems/picoruby-stackchan-protocol && bundle exec rake test TESTOPTS='--name=/test_dispatcher_frame_contract/'`
Expected: 4 failures — `assert_equal [".\n"], @stdout.frames` fails because current Dispatcher writes `"."` then `"<...>\n"` (2 calls per servo frame, but ACK is 1 byte not 2).

- [ ] **Step 5: Modify Dispatcher to emit complete frames**

Edit `mrbgems/picoruby-stackchan-protocol/examples/application.rb`:

Replace the `ACK_BYTE` / `ERROR_BYTE` constants (lines ~245-246) with frame constants:

```ruby
ACK_FRAME   = ".\n"
ERROR_FRAME = "?\n"
```

Replace `handle` (lines ~280-294) — change `@stdout.write(success ? ACK_BYTE : ERROR_BYTE)` to `@stdout.write(success ? ACK_FRAME : ERROR_FRAME)`. Same for the `rescue` branch (line ~293): `@stdout.write(ERROR_FRAME)`.

`emit_servo_detail` already writes a single multi-byte string per call (lines ~334, 346) — leave the string content unchanged, both `<ERROR:...>\n` and `<Y_actual:...>\n` are already correctly newline-terminated.

- [ ] **Step 6: Run the new test — verify GREEN**

Subagent (general-purpose, haiku): `cd mrbgems/picoruby-stackchan-protocol && bundle exec rake test TESTOPTS='--name=/test_dispatcher_frame_contract/'`
Expected: 4 pass / 0 fail.

- [ ] **Step 7: Run full mrbgems/picoruby-stackchan-protocol suite — repair any other dispatcher tests broken by the constant rename**

Subagent (general-purpose, haiku): `cd mrbgems/picoruby-stackchan-protocol && bundle exec rake test`
Expected: 100% pass. If other dispatcher tests reference `ACK_BYTE`/`ERROR_BYTE` or check raw bytes, update them to use frames (`".\n"` / `"?\n"`).

- [ ] **Step 8: Commit**

```bash
git add mrbgems/picoruby-stackchan-protocol/
git commit -m "$(cat <<'EOF'
feat(protocol): dispatcher emits complete frames per write

ACK_BYTE/ERROR_BYTE (".", "?") become ACK_FRAME/ERROR_FRAME (".\n", "?\n"). One Dispatcher#write call now passes one complete frame string to its AckSink, which the device-side BLE peripheral will forward as one BLE notification (next task).

Fixes the root cause of "unknown ack byte: \"x\"" — multi-byte detail frames mixed with single-byte ACKs into the BLE notification stream let the client misread mid-frame bytes as the next ACK.
EOF
)"
```

---

## Phase 2 — Device-side notify queue (Array of frames)

### Task 2: Replace @ack_queue (byte string) with @notify_queue (Array of frames)

**Files:**
- Modify: `mrbgems/picoruby-stackchan-protocol/examples/application.rb:492-599` (StackChanApp class)

Application code is excluded from host tests (it has `< BLE` at class-body top level — see `lib/ruby_class_extract.rb`). Verification is by on-device boot + smoke matrix.

- [ ] **Step 1: Edit StackChanApp#initialize**

Find the line `@ack_queue = ""` (around line 504). Replace with:

```ruby
@notify_queue = []
```

- [ ] **Step 2: Replace `def write(byte)` with frame-accepting version**

Find lines ~513-516:

```ruby
def write(byte)
  @ack_queue += byte
end
```

Replace with:

```ruby
# AckSink contract: Dispatcher calls write(frame_string) with one complete
# newline-terminated frame. We queue each frame as a separate element so the
# heartbeat-driven flush sends exactly one BLE notification per frame.
def write(frame)
  @notify_queue << frame
end
```

- [ ] **Step 3: Update `packet_callback` disconnect branch to clear queue**

Find the `when HCI_EVENT_DISCONNECTION_COMPLETE` branch (around line 550-552):

```ruby
when HCI_EVENT_DISCONNECTION_COMPLETE
  puts "[application] disconnected"
  @notify_enabled = false
```

Add one line after `@notify_enabled = false`:

```ruby
when HCI_EVENT_DISCONNECTION_COMPLETE
  puts "[application] disconnected"
  @notify_enabled = false
  @notify_queue = []
```

This is the second half of the bug fix: even if a frame is in flight when the central disconnects, the queue is reset so the *next* connection does not see stale data.

- [ ] **Step 4: Update heartbeat to predicate on queue size, not byte size**

Find lines ~577-579:

```ruby
if @notify_enabled && @ack_queue.bytesize > 0
  request_can_send_now_event
end
```

Replace with:

```ruby
if @notify_enabled && !@notify_queue.empty?
  request_can_send_now_event
end
```

- [ ] **Step 5: Replace `flush_one_ack` with `flush_one_frame`**

Find lines ~592-598:

```ruby
def flush_one_ack
  return if @ack_queue.bytesize == 0
  byte = @ack_queue[0, 1]
  @ack_queue = @ack_queue[1, @ack_queue.bytesize - 1] || ""
  push_read_value(@tx_handle, byte)
  notify(@tx_handle)
end
```

Replace with:

```ruby
def flush_one_frame
  return if @notify_queue.empty?
  frame = @notify_queue.shift
  push_read_value(@tx_handle, frame)
  notify(@tx_handle)
end
```

- [ ] **Step 6: Update the `ATT_EVENT_CAN_SEND_NOW` branch to call the renamed method**

Find lines ~553-554:

```ruby
when ATT_EVENT_CAN_SEND_NOW
  flush_one_ack
```

Rename to `flush_one_frame`:

```ruby
when ATT_EVENT_CAN_SEND_NOW
  flush_one_frame
```

- [ ] **Step 7: Sanity check — grep for any leftover `@ack_queue` references**

Run: `grep -n "@ack_queue\|flush_one_ack\|ACK_BYTE\|ERROR_BYTE" mrbgems/picoruby-stackchan-protocol/examples/application.rb`
Expected: no output (all replaced).

- [ ] **Step 8: Run host test suite to confirm nothing application.rb-derived broke**

Subagent (general-purpose, haiku): `cd mrbgems/picoruby-stackchan-protocol && bundle exec rake test`
Expected: 100% pass.

- [ ] **Step 9: Commit**

```bash
git add mrbgems/picoruby-stackchan-protocol/examples/application.rb
git commit -m "$(cat <<'EOF'
feat(protocol): device-side frame queue (Array) replaces byte ACK queue

@ack_queue (concatenated String) → @notify_queue (Array of frame strings).
flush_one_ack → flush_one_frame: one shift + one push_read_value + one notify
per call = exactly one BLE notification per frame.

On disconnect the queue is cleared, so a reconnect cannot see leftover bytes
from a previous session (the "x" bug observed 2026-05-19).
EOF
)"
```

---

## Phase 3 — Mac-side client adapts to frame-shaped notifications

### Task 3: parse_ack accepts a frame string, not a single byte

**Files:**
- Modify: `pc/stackchan-ble-client/lib/stackchan_ble_client/frame_codec.rb:53-60`
- Modify: `pc/stackchan-ble-client/test/test_frame_codec.rb`

- [ ] **Step 1: Find existing parse_ack test**

Run: `grep -n "parse_ack" pc/stackchan-ble-client/test/test_frame_codec.rb`

Note the test names and the byte strings they assert with (e.g. `parse_ack(".")` returning `:ok`).

- [ ] **Step 2: Write failing tests for the frame-shaped API**

Add to `pc/stackchan-ble-client/test/test_frame_codec.rb`:

```ruby
def test_parse_ack_accepts_newline_terminated_ok_frame
  assert_equal :ok, StackchanBleClient::FrameCodec.parse_ack(".\n")
end

def test_parse_ack_accepts_newline_terminated_error_frame
  assert_equal :error, StackchanBleClient::FrameCodec.parse_ack("?\n")
end

def test_parse_ack_still_accepts_bare_ack_byte_for_backcompat_with_existing_tests
  # The wire format is ".\n", but parse_ack only looks at the first byte so
  # bare-byte callers (older tests, future single-byte ACKs) keep working.
  assert_equal :ok, StackchanBleClient::FrameCodec.parse_ack(".")
end

def test_parse_ack_rejects_frame_starting_with_unknown_byte
  assert_raise(ArgumentError) { StackchanBleClient::FrameCodec.parse_ack("<Y_actual:0,P_actual:600>\n") }
end
```

- [ ] **Step 3: Run tests to verify the first two fail**

Subagent (general-purpose, haiku): `cd pc/stackchan-ble-client && bundle exec rake test TESTOPTS='--name=/parse_ack/'`
Expected: 2 fail (newline-terminated cases), 2 pass (bare byte, unknown frame).

Why bare-byte + unknown still pass: current `parse_ack` does `case byte` against single-character `ACK_OK` / `ACK_ERROR`; multi-byte input never matches and falls into the `raise`. So `parse_ack(".\n")` currently raises — which is what we are fixing.

- [ ] **Step 4: Modify parse_ack to look at the first byte only**

Edit `pc/stackchan-ble-client/lib/stackchan_ble_client/frame_codec.rb:53-60`:

```ruby
def parse_ack(frame)
  case frame[0, 1]
  when ACK_OK    then :ok
  when ACK_ERROR then :error
  else
    raise ArgumentError, "unknown ack frame: #{frame.inspect}"
  end
end
```

(`frame[0, 1]` is safe on a 1-char string too — returns the same 1 char.)

- [ ] **Step 5: Run parse_ack tests — verify GREEN**

Subagent (general-purpose, haiku): `cd pc/stackchan-ble-client && bundle exec rake test TESTOPTS='--name=/parse_ack/'`
Expected: 4 pass / 0 fail.

- [ ] **Step 6: Run full pc/stackchan-ble-client suite**

Subagent (general-purpose, haiku): `cd pc/stackchan-ble-client && bundle exec rake test`
Expected: 100% pass.

- [ ] **Step 7: Run full pc/stackchan-notifier suite (worker/handlers should be unaffected)**

Subagent (general-purpose, haiku): `cd pc/stackchan-notifier && bundle exec rake test`
Expected: 100% pass (71 tests).

- [ ] **Step 8: Commit**

```bash
git add pc/stackchan-ble-client/
git commit -m "$(cat <<'EOF'
feat(ble-client): parse_ack accepts frame string

The Mac client now treats one BLE notification = one frame. parse_ack
reads the first byte of the received frame (typically the 2-byte ".\n" or
"?\n") instead of the bare ACK byte. The error message renames "ack byte"
to "ack frame" to make wire mismatches more obvious in logs.
EOF
)"
```

---

## Phase 4 — Build + deploy + smoke

### Task 4: Build, flash, and redeploy application.rb

**Files:** none (deploy only)

- [ ] **Step 1: Run `r2p2:setup` only if `picogem_init.c` is stale**

Determine staleness with `ls -lt /Users/bash/dev/src/github.com/bash0C7/R2P2-ESP32/build/esp-idf/main/include/picogem_init.c 2>/dev/null` — if the file does not exist or is older than today, setup is needed. Otherwise skip to Step 2.

If needed: `/stackchan-device-setup` (haiku subagent, 1200s timeout).

- [ ] **Step 2: Build + flash firmware**

`/stackchan-device-build-flash` (haiku subagent, 600s timeout).

Expected: rake exits 0; flash log shows `Hash of data verified.`

- [ ] **Step 3: Upload the patched application.rb as the autostart payload**

Skill: `stackchan-device-deploy-app` with `SRC=mrbgems/picoruby-stackchan-protocol/examples/application.rb`.

(`deploy-app` does upload-appmrb + reset.)

- [ ] **Step 4: Verify boot completes cleanly**

Skill: `stackchan-device-boot-verify` (chain — reset + capture + analyze).

Expected markers in `/tmp/stackchan-picoruby-debug/boot.log`:
- `[application] LCD + LED cold-boot done`
- `[boot] servo init OK`
- `[application] HCI WORKING — advertising`
- `[application] heartbeat` (multiple)
- No `Guru Meditation Error`

If panic: `stackchan-device-crash-analyze` is auto-invoked by boot-verify; inspect output before proceeding.

### Task 5: Smoke matrix A1-A9 (handoff Section A)

**Files:** none (smoke only)

- [ ] **Step 1: Launch the notifier daemon as a background process**

```bash
cd pc/stackchan-notifier && rm -f /tmp/stackchan-notifier-501.sock /tmp/stackchan-picoruby-debug/notifier-daemon.log
BLE_DEVICE_NAME=StackChan-PicoRuby nohup bundle exec exe/stackchan-notifier-daemon --log-level debug > /tmp/stackchan-picoruby-debug/notifier-daemon.log 2>&1 &
disown
```

Wait until `tail -n 5 /tmp/stackchan-picoruby-debug/notifier-daemon.log` shows `BLE connected`. If it shows `no device named` repeatedly, the device window expired — wait ~10 s and re-check; the daemon will retry automatically.

- [ ] **Step 2: A1 — face joy with motion**

```bash
cd pc/stackchan-notifier && bundle exec exe/stackchan-notify --face joy
sleep 2
tail -n 10 /tmp/stackchan-picoruby-debug/notifier-daemon.log
```

Expected: no `unknown ack frame` exception, no `worker terminated`. Visual: face = joy, head tilts up (pitch ~600).

- [ ] **Step 3: A2 — face sad + left LED red blink**

```bash
bundle exec exe/stackchan-notify --face sad --left_led red,blink
sleep 2
tail -n 10 /tmp/stackchan-picoruby-debug/notifier-daemon.log
```

Visual: face = sad, head down (pitch ~280), LEFT LED red blink (note: `--left_led` argument refers to StackChan's left from its own POV; on the wire this maps to `S:R`).

- [ ] **Step 4: A3 — face joy --silent (no motion)**

```bash
bundle exec exe/stackchan-notify --face joy --silent
sleep 2
tail -n 10 /tmp/stackchan-picoruby-debug/notifier-daemon.log
```

Visual: face = joy, head does NOT move (stays at A2's pitch ~280).

- [ ] **Step 5: A4 — face neutral with duration restore**

```bash
bundle exec exe/stackchan-notify --face neutral --duration 3
sleep 5
tail -n 15 /tmp/stackchan-picoruby-debug/notifier-daemon.log
```

Visual: face = neutral immediately, head level (pitch ~450). After 3 s the daemon writes a second tuple restoring neutral + LEDs off + silent.

- [ ] **Step 6: A5/A6/A7 — direct servo CLI**

```bash
bundle exec exe/stackchan-servo --yaw 1000 --pitch 450 --time 500
sleep 2
bundle exec exe/stackchan-servo --yaw -1000 --pitch 450 --time 500
sleep 2
bundle exec exe/stackchan-servo --yaw 0 --pitch 800
sleep 2
tail -n 20 /tmp/stackchan-picoruby-debug/notifier-daemon.log
```

Visual: head pans right (500 ms), left (500 ms), looks straight up (max pitch).

- [ ] **Step 7: A8 — raw frame**

```bash
bundle exec exe/stackchan-raw --frame '<F:2>'
sleep 2
tail -n 10 /tmp/stackchan-picoruby-debug/notifier-daemon.log
```

Visual: face = joy (F:2 = joy index).

- [ ] **Step 8: A9 — burst coalesce**

```bash
for i in 1 2 3 4 5; do bundle exec exe/stackchan-notify --face joy --silent; done
sleep 3
grep -c "deliver" /tmp/stackchan-picoruby-debug/notifier-daemon.log || true
tail -n 25 /tmp/stackchan-picoruby-debug/notifier-daemon.log
```

Expected: the daemon log shows the 5 tuples were drained into a single dispatch (only one set of BLE writes per burst; check that there is one ACK round-trip per kind, not five).

- [ ] **Step 9: Shut down daemon cleanly**

```bash
pkill -INT -f stackchan-notifier-daemon
sleep 2
ls /tmp/stackchan-notifier-501.sock 2>&1
```

Expected: socket file removed, `pkill` exited 0.

- [ ] **Step 10: Commit smoke verification note (if everything passed)**

Add a one-line entry to the handoff doc OR create a follow-up handoff capturing the result. Don't commit code from this task — it's verification only.

```bash
# Update handoff status to "device-verified" — exact edit depends on outcome.
git add docs/superpowers/
git commit -m "docs(handoff): notifier 2.0 smoke A1-A9 PASS after wire-protocol redesign"
```

---

## Phase 5 — Final review

### Task 6: Code-reviewer subagent pass

- [ ] **Step 1: Run a code-reviewer subagent over the diff range**

Subagent (feature-dev:code-reviewer): give it the commit range `HEAD~5..HEAD` (or whatever the actual range of this plan ended up being — `git log --oneline` to check). Ask it to focus on:
- The wire protocol contract (Phase 1/2): is there any code path that still writes a single byte to `@notify_queue` instead of a complete frame?
- Disconnect handling (Task 2 Step 3): does any path bypass the queue clear?
- Client parse_ack (Task 3): is the bare-byte back-compat path actually reachable, or should we drop it for clarity?
- Test coverage: is there a regression test that would catch a future "detail frame written to byte stream" mistake?

Address any HIGH-confidence findings inline; cite the file:line of each change in the response.

---

## Self-Review notes (filled by author at write-time)

- **Spec coverage:** Bug analysis (ACK queue contamination + stale queue across reconnect) is addressed by Phase 1 (frame contract on write side), Phase 2 (Array queue + disconnect clear on device), Phase 3 (parse_ack reads frame). Smoke matrix A1-A9 is exactly Section A of the handoff. Task 14 explicitly out of scope for this plan but unblocked.
- **Placeholder scan:** none.
- **Type consistency:** `ACK_FRAME`/`ERROR_FRAME` introduced in Task 1 Step 5, referenced consistently in Task 2 Step 7 grep, no `ACK_BYTE`/`ERROR_BYTE` survives the commits.
