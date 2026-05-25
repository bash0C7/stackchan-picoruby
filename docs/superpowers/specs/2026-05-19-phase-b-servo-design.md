# Phase B: Servo Control (Yaw / Pitch with Time-Velocity Policy) Design

> **⚠ SUPERSEDED by `2026-05-21-cold-boot-torque-off-and-normalized-protocol-design.md`.**
> The raw Y/P frame protocol described in this document was retired on 2026-05-21
> in favour of a direction-key + magnitude protocol (`<YL:N,YR:N,PU:N>`).
> Cold-boot also no longer auto-enables torque or runs self-test.
> This document is preserved as a Phase B historical reference only.

Date: 2026-05-19

## Goal

Bring StackChan's two FEETECH SCServo SCSCL feedback servos (yaw / pitch) under PicoRuby control so that Mac-side clients can command head movement over BLE NUS. Phase B scope covers:

1. Absolute position commands (yaw / pitch in raw degree units)
2. Velocity / movement-time control (T-priority, V fallback)
3. ReadPos-based auto-verification feedback to the Mac side
4. Explicit error frames on servo failure (UART timeout)

Gesture macros (nod / shake / look_at), self-initiated push notifications (heartbeat / alerts), and head-touch-driven reactions are deferred to Phase C+.

## Architecture

```
                  Mac side
                  ┌─────────────────────────┐ ┌──────────────────────────┐
                  │ stackchan-ble-control   │ │ stackchan-notifier (hook)│
                  │  servo --yaw ... --time │ │  servo trigger on event  │
                  └────────────┬────────────┘ └──────────┬───────────────┘
                               └─────────────┬──────────┘
                                      ┌──────▼──────┐
                                      │ BLE client  │
                                      │  (NUS RX/TX)│
                                      └──────┬──────┘
                  ─────────────────── BLE ──── │ ────────────────────────────
                                               ▼   write: <Y:-300,P:500,T:2000>
                                                   notify: <Y_actual:-298,P_actual:497>
                                                   notify: <ERROR:servo_timeout,axis:yaw>
                  Device side (PicoRuby on ESP32-S3)
                  ┌──────────────────────────────────────────────────────┐
                  │ application.rb                                       │
                  │ ┌────────────────────────────┐                       │
                  │ │ StackchanApp::Dispatcher   │ (Phase A 既存 + 拡張) │
                  │ └─────────────┬──────────────┘                       │
                  │  ┌────────────▼─────────────┐                        │
                  │  │ StackchanApp::Head  NEW  │ (yaw/pitch alias,     │
                  │  └────────────┬─────────────┘  range, T-V policy)   │
                  └───────────────│──────────────────────────────────────┘
                                  ▼
                  ┌──────────────────────────────────────────────────────┐
                  │ picoruby-scservo (mrbgem)                       NEW  │
                  │   class SCServo                                      │
                  │     #write_pos / #read_pos / #enable_torque          │
                  └───────────────┬──────────────────────────────────────┘
                                  ▼
                  ┌──────────────────────────────────────────────────────┐
                  │ picoruby-uart (既存組込済)                            │
                  │   UART_NUM_1, 1_000_000 baud, TXD=GPIO 6, RXD=GPIO 7 │
                  │   ※ 2026-05-20 fix: 旧 spec は RXD/TXD を逆記載。    │
                  │     公式 hal_servo.cpp:169 と e42df29 commit で訂正。  │
                  └───────────────┬──────────────────────────────────────┘
                                  ▼
                            ┌──────────┐
                            │ SCServo  │ × 2 (ID 1=yaw, ID 2=pitch)
                            └──────────┘
```

Dependency direction: `application -> picoruby-scservo -> picoruby-uart`. The `picoruby-scservo` gem stays generic (FEETECH SCSCL protocol only); StackChan-specific knowledge (yaw / pitch axis mapping, angle limits, T-V policy) lives in `StackchanApp::Head` inside `application.rb`. This mirrors the Phase A split: `picoruby-stackchan-protocol::FrameParser` (generic framework) vs `StackchanApp::Face` (StackChan-specific).

Iteration cost:
- Firmware change (new gem build, gem layout, `picogem_init.c` regenerate): `rake r2p2:full_rebuild`, ~7 min
- Application change (`StackchanApp::Head` / Dispatcher routing): `/stackchan-device-deploy-app` chain, ~20 s

## Components

### Firmware: `mrbgems/picoruby-scservo` (NEW)

Layout follows `picoruby-mpu6886` / `picoruby-vl53l0x`:

```
mrbgems/picoruby-scservo/
├── mrbgem.rake               # spec.add_dependency 'picoruby-uart'
├── mrblib/
│   └── scservo.rb            # class SCServo
└── test/
    └── test_scservo.rb       # host test (test-unit + mock UART)
```

API:

```ruby
class SCServo
  INSTR_WRITE      = 0x03
  INSTR_READ       = 0x02
  REG_TORQUE       = 0x28
  REG_GOAL_POS_L   = 0x2A
  REG_PRESENT_POS_L = 0x38

  def initialize(uart, id:)
  def write_pos(pos, time_ms: 0, speed: 0)   # SCS WritePos (pos+time+speed bundled write)
  def read_pos                                # SCS ReadPos -> 16bit raw position, nil on timeout
  def enable_torque(on = true)
  def set_mode(mode)                          # :position or :pwm
end
```

Wire-level SCS packet format (`0xFF 0xFF [ID] [length] [instr] [params] [checksum]`) is assembled with `Array#pack('C*')` and sent via `uart.write`. Read responses are parsed by reading expected bytes from `uart.gets` with a 50 ms timeout. ID 0xFE is the broadcast ID (no response expected).

**WritePos ACK handling**: FEETECH SCServo by default returns a 6-byte status packet for non-broadcast writes. `SCServo#write_pos` **drains any pending bytes from the UART RX buffer before returning** (best-effort `uart.read(64, timeout_ms: 5)` and discard). This prevents the next `read_pos` from accidentally consuming a stale WritePos ACK and misinterpreting it as a ReadPos response. The drain is sized for two servos × 6 bytes plus margin.

### Application: `StackchanApp::Head` (NEW, in `application.rb`)

```ruby
module StackchanApp
  class Head
    YAW_RANGE   = (-1280..1280)
    PITCH_RANGE = (30..870)

    def initialize(yaw_servo, pitch_servo)
      @yaw   = yaw_servo
      @pitch = pitch_servo
    end

    def apply(frame)
      # T-priority, V fallback, both absent -> max speed (0, 0)
      if frame.key?("T")
        time_ms = frame["T"] ; speed = 0
      elsif frame.key?("V")
        time_ms = 0 ; speed = frame["V"]
      else
        time_ms = 0 ; speed = 0
      end
      if frame.key?("Y")
        y = clamp(frame["Y"], YAW_RANGE)
        @yaw.write_pos(y, time_ms: time_ms, speed: speed)
      end
      if frame.key?("P")
        p = clamp(frame["P"], PITCH_RANGE)
        @pitch.write_pos(p, time_ms: time_ms, speed: speed)
      end
    end

    def read_actual
      y = @yaw.read_pos
      p = @pitch.read_pos
      { "Y_actual" => y, "P_actual" => p }
    end

    private
    def clamp(v, range)
      return range.first if v < range.first
      return range.last  if v > range.last
      v
    end
  end
end
```

### Application: `StackchanApp::Dispatcher` extension

Existing Dispatcher (Phase A) handles `F` / `M` / `S` / `R` / `G` / `B`. Phase B adds a head branch:

```ruby
# (Phase A) earlier in handle(): emit byte ACK `.` or `?` as today
if frame.key?("Y") || frame.key?("P") || frame.key?("V") || frame.key?("T")
  @head.apply(frame)
  actual = @head.read_actual
  if actual["Y_actual"].nil? || actual["P_actual"].nil?
    failed = []
    failed << "yaw"   if actual["Y_actual"].nil? && frame.key?("Y")
    failed << "pitch" if actual["P_actual"].nil? && frame.key?("P")
    axis = failed.size == 2 ? "both" : failed.first
    send_extra_frame("<ERROR:servo_timeout,axis:#{axis}>")
  else
    send_extra_frame("<Y_actual:#{actual['Y_actual']},P_actual:#{actual['P_actual']}>")
  end
end
```

`send_extra_frame` is a new helper that emits a separate NUS notify carrying the detail frame **after** the existing byte ACK. Implementation reuses the existing BTstack notify path (`@parser.ack_queue.push` style) but with full frame string instead of single byte.

Servo handling is independent from existing face / LED branches; mixed frames (e.g. `<F:3,Y:-200>`) flow through both branches in the same dispatch call (Phase A combo precedent).

### Application: cold-boot initialization

In the cold-boot block at the top of `application.rb` (after AXP2101 / AW9523 / SPI / ILI9342 / LED init, before `BLE.new`):

```ruby
begin
  servo_uart = UART.new(unit: :ESP32_UART1, txd_pin: 7, rxd_pin: 6, baudrate: 1_000_000)
  yaw_servo   = SCServo.new(servo_uart, id: 1)
  pitch_servo = SCServo.new(servo_uart, id: 2)
  yaw_servo.enable_torque
  pitch_servo.enable_torque
  @head = StackchanApp::Head.new(yaw_servo, pitch_servo)
rescue => e
  puts "servo init failed: #{e.class}: #{e.message}"
  @head = nil   # face / LED は健常を維持、servo frame は ERROR を返す
end
```

When `@head` is `nil`, the Dispatcher servo branch returns `<ERROR:servo_unavailable>`.

### Mac side: `pc/stackchan-ble-client` CLI

`stackchan-ble-control` gains a `servo` subcommand:

```
stackchan-ble-control servo [--yaw N] [--pitch N] [--time MS] [--velocity N]
                            [--name-prefix StackChanCoreS3] [--timeout SEC]
```

Output is the device's response frame (either `<Y_actual:..,P_actual:..>` or `<ERROR:...>`). Exit code 0 on actual frame, non-zero on `<ERROR:...>` or BLE timeout.

### Mac side: `pc/stackchan-notifier`

New event-to-frame mapping in the notifier hook config maps notification events to servo frames. Example: GitHub PR notification triggers a small `<Y:-100,T:300>` + `<Y:100,T:300>` sequence ("nod" emulated as a 2-frame burst from the Mac side, since gesture macros are out of scope for the device). The notifier sends frames serially through the existing BLE client connection.

## Data flow

### Path A: Mac → device (commanding)

1. CLI invokes `stackchan-ble-control servo --yaw -300 --pitch 500 --time 2000`
2. BLE client writes `<Y:-300,P:500,T:2000>\n` to NUS RX characteristic
3. Device BLE handler feeds chunk to `FrameParser.feed`; parser yields `{"Y"=>-300, "P"=>500, "T"=>2000}` once the closing `>` and newline arrive
4. `Dispatcher.handle(frame)` matches Y/P/V/T branch → `@head.apply(frame)`
5. `Head#apply` clamps values, calls `@yaw.write_pos(-300, time_ms: 2000)` and `@pitch.write_pos(500, time_ms: 2000)`
6. `SCServo#write_pos` assembles the SCS packet (REG_GOAL_POS_L + REG_TIME_L + REG_SPEED_L bundled write) and sends it over UART
7. Physical servos move toward target over the specified time

### Path B: device → Mac (response)

8. Immediately after `apply`, Dispatcher emits the existing Phase A single-byte ACK (`.` = OK or `?` = error) via NUS TX notify, preserving compatibility with face / LED handling
9. Dispatcher then calls `@head.read_actual`; `SCServo#read_pos` sends a SCS ReadPos request, waits up to 50 ms for response, parses the returned 16-bit raw position
10. Dispatcher emits an **additional NUS TX notify** with detail:
    - On success: `<Y_actual:-298,P_actual:497>\n`
    - On timeout: `<ERROR:servo_timeout,axis:yaw|pitch|both>\n`
    The Phase A wire stays untouched (still byte `.`/`?` for face/LED). The Phase B servo branch sends both: byte ACK first, then the structured detail frame. Mac client matches detail frame by leading `<` (frame) vs single byte
11. Mac client receives both notifies in order, ACK byte sets the exit code domain, detail frame supplies actual position / error info to stdout

### Timing note

The ReadPos reply is captured **just after** `write_pos` returns, so for any non-zero `T` the servo is still mid-motion. ReadPos in Phase B is a **command-receipt confirmation** ("the servo controller acknowledged my command"), not a movement-completion check. Polling for "did it actually reach the target" is deferred to Phase C+ if needed.

## Error handling

### Range violation
- `Head#apply` clamps to `YAW_RANGE` / `PITCH_RANGE`; no exception
- Mac learns the clamped result through the `Y_actual` / `P_actual` notify (no explicit "clamped" signal)
- Rationale: servo position is a continuous value; physical-range clamping is the natural mapping. Contrast with `F:9` (nonexistent face) which is rejected with ERROR

### UART timeout (servo not responding)
- `SCServo#read_pos` returns `nil` after 50 ms with no response
- `Head#read_actual` propagates `nil`
- Dispatcher emits `<ERROR:servo_timeout,axis:yaw|pitch|both>` notify
- `write_pos` does not wait for a response (fire-and-forget), so timeouts arise only on read paths

### Cold-boot init failure
- If `UART.new` or initial `enable_torque` raises, the rescue block sets `@head = nil`
- BLE and face / LED branches continue working; servo branch returns `<ERROR:servo_unavailable>`
- Degradation policy: a broken servo subsystem does not block face / LED Phase A functionality

### Frame protocol error
- `<Y:abc>` (non-integer) is rejected by the existing FrameParser; Dispatcher returns ERROR (Phase A behavior)
- Missing `T` and `V` with `Y` / `P` specified → both default to 0 → SCServo treats this as "max speed" (FEETECH vendor behavior)
- `Y` without `P` → yaw moves, pitch holds (each axis independently triggered)

### No silent rescue
- Per `~/dev/src/CLAUDE.md` "No Silent Exception Swallowing": UART read timeout returns `nil` (Result-style), not `rescue nil`
- Cold-boot servo init failure logs via `puts` (visible in monitor) before degrading; not propagated to main loop

## Testing

### Host tests (`rake test` via subagent)

Three new test files:

| File | Subject | Coverage |
|---|---|---|
| `mrbgems/picoruby-scservo/test/test_scservo.rb` | `SCServo` class | `write_pos` packet byte assembly (header / ID / length / instr / params / checksum), `read_pos` reply parsing, timeout → `nil`, mock UART |
| `test/test_head.rb` | `StackchanApp::Head` | Out-of-range value clamps to `YAW_RANGE` / `PITCH_RANGE`, T-priority (T present → speed ignored), `read_actual` shape including nil propagation |
| `test/test_dispatcher_servo.rb` | `Dispatcher` extension | Y/P/V/T frame routes to `@head.apply`, mixed frame `<F:3,Y:-200>` routes to both face and head, `nil` from `read_actual` triggers `<ERROR:servo_timeout,...>` |

Target: existing 19 PASS + ~15 new = ~34 PASS, 0 omit (Phase A discipline maintained).

### Device-side auto-verify (`stackchan-device-servo-verify` skill, NEW)

Procedure:
1. Deploy current `application.rb` via `/stackchan-device-iterate`
2. Send `<Y:0,P:500,T:0>` via BLE (center pose at max speed)
3. Wait 200 ms for movement to complete
4. Send `<Y:0,P:500,T:0>` again and capture the response notify
5. Assert `|Y_actual| <= 5` and `|P_actual - 500| <= 5`
6. Repeat for `<Y:-300,P:500,T:0>` and `<Y:300,P:500,T:0>`
7. Exit code 0 on all PASS, non-zero on any FAIL

This is the Phase B analog of `stackchan-device-face-verify` (Phase A golden-SHA).

### HITL gate (human visual verification)

A new `docs/superpowers/handoff/phase-b-hitl-checklist.md` will be created during implementation. Tester sends a fixed sequence (center, full-right, full-left, full-down, full-up, slow-pan over 3 s) and confirms smoothness, absence of buzz / overheat, and target accuracy by eye. Verification is recorded as a timestamped log entry appended to the same checklist file (per Phase A precedent for face HITL).

### Boot-failure regression
- A temporary edit to set `txd_pin: 99` (nonexistent GPIO) confirms the rescue path: device boots, BLE adv continues, servo frames return `<ERROR:servo_unavailable>`. Reverted before commit.
- Standard cold-boot health check via `/stackchan-device-boot-verify` (no Guru, no `Returned from app_main`) covers normal path.

## Out of scope (deferred to Phase C+)

- Gesture macros (`nod`, `shake`, `look_at`) on the device; Mac-side multi-frame sequences via `stackchan-notifier` are allowed
- Self-initiated BLE notifies (`HEARTBEAT`, `ALERT`, `EVENT:touched`); designed jointly with the kawaii-ai-robot environmental-response loop
- Head-touch (Si12T) reactive movement; needs touch driver + integration with face + servo + LLM
- Servo overheat / overload monitoring; SCServo exposes register reads for these but no Phase B consumer
- Movement-completion polling (`is the servo at the target yet?`); Phase B treats ReadPos as receipt acknowledgement only
- Servo ID reassignment / configuration writing; Phase B assumes factory ID 1 = yaw, ID 2 = pitch

## Decisions log (brainstorming results, 2026-05-19)

| Topic | Decision | Rationale |
|---|---|---|
| Phase B scope | B-1 (position) + B-2 (velocity / time), no gesture macros | Macros are Mac-side composable from raw frames; building them on-device locks the design too early |
| Value unit | Raw degrees (yaw -1280..+1280, pitch 30..870) | Direct match with SCServo internal scale; LLM is told "yaw range is -1280..+1280" explicitly; no abstraction leakage |
| Frame keys | Y / P / V / T (Yaw / Pitch / Velocity / Time) | Aligns with SCServo firmware naming; AI-friendly aviation terms; no collision with existing F/M/S/R/G/B |
| Time vs velocity | T priority, V fallback, both absent → max speed | LLM prefers time-language ("over 2 seconds"); SCServo natively supports time |
| HITL strategy | ReadPos auto-verify first, then human visual HITL | ReadPos is the foundation; if broken, visual check is meaningless |
| Mac-side surface | `stackchan-ble-control servo` subcommand + `stackchan-notifier` hook extension | Both consumer paths in Phase B; CLI for ad-hoc and tests, notifier for automation |
| Gem boundary | Two-layer: `picoruby-scservo` (generic SCSCL) + `StackchanApp::Head` (app-side, StackChan-specific) | Mirrors Phase A `FrameParser` + `Face` split; preserves Design D firmware/application boundary |
| Failure surface | Explicit `<ERROR:...>` frames in Phase B; self-push deferred | Explicit ERROR is cheap and clean; self-push needs Phase C+ environmental-loop design |
