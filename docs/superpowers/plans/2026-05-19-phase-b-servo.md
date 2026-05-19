# Phase B Servo Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add SCServo (FEETECH SCSCL) yaw/pitch control to StackChan via a new `picoruby-scservo` mrbgem and a new `StackchanApp::Head` class, exposed over BLE NUS frame protocol (`Y` / `P` / `V` / `T` keys), with Mac-side CLI and notifier extensions.

**Architecture:** Two-layer split — `picoruby-scservo` gem holds generic FEETECH SCSCL UART wire protocol; `StackchanApp::Head` in `application.rb` holds StackChan-specific axis mapping, range clamp, and T-priority/V-fallback policy. Dispatcher gets a new `handle_head` branch that emits the standard 1-byte ACK plus a structured detail frame carrying actual position or error. Mirrors the Phase A `FrameParser` (generic) + `Face` (StackChan-specific) split.

**Tech Stack:** PicoRuby (R2P2-ESP32), FEETECH SCServo SCSCL series, ESP32-S3 UART_NUM_1 @ 1 Mbps GPIO 6/7, BLE NUS, Mac-side Ruby (test-unit), prism AST extract for host tests.

**Spec reference:** `docs/superpowers/specs/2026-05-19-phase-b-servo-design.md`

---

## File Structure

### New files (device side)

| Path | Responsibility |
|---|---|
| `mrbgems/picoruby-scservo/mrbgem.rake` | gem spec, depends on `picoruby-uart` |
| `mrbgems/picoruby-scservo/mrblib/scservo.rb` | `class SCServo` — packet assembly, UART RX/TX, timeout |

### Modified files (device side)

| Path | Change |
|---|---|
| `mrbgems/picoruby-stackchan-protocol/examples/application.rb` | Add `StackchanApp::Head` class; extend `Dispatcher#handle` with `handle_head`; cold-boot servo init block; wire `@head` into `StackChanApp` |
| `~/dev/src/github.com/bash0C7/R2P2-ESP32/components/picoruby-esp32/build_config/xtensa-esp-picoruby.rb` | Add `conf.gem gemdir: '/Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/mrbgems/picoruby-scservo'` |

### New files (host test side)

| Path | Responsibility |
|---|---|
| `test/scservo_test.rb` | Host unit test for `SCServo` with FakeUART |
| `test/head_test.rb` | Host unit test for `StackchanApp::Head` with mock SCServo |
| `test/dispatcher_servo_test.rb` | Host unit test for Dispatcher Y/P/V/T branch |
| `test/fake_uart.rb` | Reusable FakeUART double (writes / reads / timeout simulation) |

### Modified files (host test side)

| Path | Change |
|---|---|
| `test/test_helper.rb` | Pre-declare `UART` const stub so application.rb's class definitions resolve |

### New / modified files (Mac side)

| Path | Change |
|---|---|
| `pc/stackchan-ble-client/lib/stackchan_ble_client/send_builder.rb` | Add `#head(yaw:, pitch:, time:, velocity:)` method |
| `pc/stackchan-ble-client/lib/stackchan_ble_client/frame_codec.rb` | Add `encode_head` |
| `pc/stackchan-ble-client/exe/stackchan-ble-control` | Add `servo` subcommand |
| `pc/stackchan-notifier/lib/stackchan_notifier/worker.rb` | Add `:servo` tuple case in `handle_tuple` |

### New skill / docs

| Path | Responsibility |
|---|---|
| `.claude/skills/stackchan-device-servo-verify/SKILL.md` | Phase B device-side auto-verify (counterpart to face-verify) |
| `docs/superpowers/handoff/phase-b-hitl-checklist.md` | Human visual verification log template |

---

## Task 1: picoruby-scservo gem scaffold + UART stub + FakeUART

**Files:**
- Create: `mrbgems/picoruby-scservo/mrbgem.rake`
- Create: `mrbgems/picoruby-scservo/mrblib/scservo.rb`
- Create: `test/fake_uart.rb`
- Modify: `test/test_helper.rb` (add `UART` const stub + load `fake_uart` + load `scservo.rb`)
- Create: `test/scservo_test.rb` (smoke test only — class loads)

- [ ] **Step 1: Write mrbgem.rake**

```ruby
# mrbgems/picoruby-scservo/mrbgem.rake
MRuby::Gem::Specification.new('picoruby-scservo') do |spec|
  spec.license = 'MIT'
  spec.author  = 'bash0C7'
  spec.summary = 'FEETECH SCServo SCSCL series UART driver - pure Ruby PicoRuby Runtime Gem'

  spec.add_dependency 'picoruby-uart'
  spec.add_test_dependency 'picoruby-picotest'
end
```

- [ ] **Step 2: Write scservo.rb scaffold**

```ruby
# mrbgems/picoruby-scservo/mrblib/scservo.rb
require 'uart'

class SCServo
  HEADER          = [0xFF, 0xFF].freeze
  INSTR_PING      = 0x01
  INSTR_READ      = 0x02
  INSTR_WRITE     = 0x03
  REG_TORQUE      = 0x28
  REG_GOAL_POS_L  = 0x2A  # GoalPos(2) + Time(2) + Speed(2) bundled write
  REG_MODE        = 0x21  # 0 = position, 1 = PWM
  REG_PRESENT_POS_L = 0x38
  READ_TIMEOUT_MS = 50
  DRAIN_TIMEOUT_MS = 5
  DRAIN_BUDGET_BYTES = 64

  def initialize(uart, id:)
    @uart = uart
    @id   = id
  end
end
```

- [ ] **Step 3: Create test/fake_uart.rb**

```ruby
# test/fake_uart.rb
class FakeUART
  attr_reader :writes
  attr_accessor :read_queue

  def initialize
    @writes     = []
    @read_queue = []   # each element: { bytes: [..], delay_ms: 0 } or :timeout
  end

  def write(bytes)
    @writes << bytes
  end

  def read(n, timeout_ms: 0)
    item = @read_queue.shift
    return nil if item.nil? || item == :timeout
    bytes = item[:bytes]
    return nil if bytes.empty?
    bytes.first(n)
  end

  def gets
    item = @read_queue.shift
    return nil if item.nil? || item == :timeout
    item[:bytes].pack('C*')
  end
end
```

- [ ] **Step 4: Modify test/test_helper.rb to add UART stub and fake_uart require**

Add immediately after the BLE stub block (after line 15-16):

```ruby
# Pre-declare UART class so SCServo's `require 'uart'` resolves on host
Object.const_set(:UART, Class.new) unless defined?(UART)
```

Add at the bottom of the file (after the existing RubyClassExtract.load_classes_from line):

```ruby
require 'fake_uart'

# Load the picoruby-scservo gem's pure Ruby class from the mrbgems tree
SCSERVO_PATH = File.expand_path(
  '../mrbgems/picoruby-scservo/mrblib/scservo.rb', __dir__
)
load SCSERVO_PATH
```

- [ ] **Step 5: Write smoke test/scservo_test.rb**

```ruby
# test/scservo_test.rb
$LOAD_PATH.unshift(File.expand_path('.', __dir__))
require 'test_helper'

class SCServoTest < Test::Unit::TestCase
  def test_initializes_with_uart_and_id
    uart = FakeUART.new
    servo = SCServo.new(uart, id: 1)
    assert_kind_of SCServo, servo
  end
end
```

- [ ] **Step 6: Run test to verify it passes**

```bash
bundle exec rake test TESTOPTS="--name=SCServoTest"
```

Delegate this `rake test` invocation to a haiku subagent per CLAUDE.md "Ruby Testing / Test Execution Delegation". Expected: 1 PASS, 0 omit.

- [ ] **Step 7: Commit**

```bash
git add mrbgems/picoruby-scservo/mrbgem.rake mrbgems/picoruby-scservo/mrblib/scservo.rb test/fake_uart.rb test/test_helper.rb test/scservo_test.rb
git commit -m "feat(scservo): scaffold picoruby-scservo gem + host UART stub"
```

---

## Task 2: SCServo#write_pos packet assembly

**Files:**
- Modify: `mrbgems/picoruby-scservo/mrblib/scservo.rb`
- Modify: `test/scservo_test.rb`

SCS WritePos packet format (FEETECH SCSCL):
```
0xFF 0xFF [ID] [LEN] [INSTR=0x03] [REG=0x2A] [pos_L pos_H] [time_L time_H] [speed_L speed_H] [CKSUM]
```
LEN = number of bytes after LEN itself = INSTR(1) + REG(1) + DATA(6) + CKSUM(1) = 9.
CKSUM = `~(ID + LEN + INSTR + REG + DATA...) & 0xFF`.

- [ ] **Step 1: Add failing test for write_pos byte sequence**

Append to `test/scservo_test.rb`:

```ruby
  def test_write_pos_emits_correct_packet
    uart = FakeUART.new
    servo = SCServo.new(uart, id: 1)
    servo.write_pos(500, time_ms: 1000, speed: 0)
    # ID=1, LEN=9, INSTR=0x03, REG=0x2A,
    # pos=500=0x01F4 -> [0xF4,0x01], time=1000=0x03E8 -> [0xE8,0x03], speed=0 -> [0x00,0x00]
    # checksum = ~(1+9+3+0x2A+0xF4+1+0xE8+3+0+0) & 0xFF
    #         = ~(1+9+3+42+244+1+232+3+0+0) & 0xFF = ~0x17 & 0xFF = 0xE8
    expected = [0xFF, 0xFF, 0x01, 0x09, 0x03, 0x2A,
                0xF4, 0x01, 0xE8, 0x03, 0x00, 0x00, 0xE8]
    assert_equal expected, uart.writes.first
  end

  def test_write_pos_with_zero_time_and_speed_means_max_speed
    uart = FakeUART.new
    servo = SCServo.new(uart, id: 2)
    servo.write_pos(300, time_ms: 0, speed: 0)
    # pos=300=0x012C -> [0x2C, 0x01], time=0 -> [0,0], speed=0 -> [0,0]
    # sum = 2+9+3+0x2A+0x2C+1+0+0+0+0 = 2+9+3+42+44+1 = 101 = 0x65
    # checksum = ~0x65 & 0xFF = 0x9A
    expected = [0xFF, 0xFF, 0x02, 0x09, 0x03, 0x2A,
                0x2C, 0x01, 0x00, 0x00, 0x00, 0x00, 0x9A]
    assert_equal expected, uart.writes.first
  end

  def test_write_pos_signed_position_uses_sign_bit_high_byte
    # SCS encodes negative positions with bit 15 = sign on yaw raw scale.
    # For yaw -300, raw = 300 with sign bit set -> high byte 0x01 | 0x80 = 0x81
    uart = FakeUART.new
    servo = SCServo.new(uart, id: 1)
    servo.write_pos(-300, time_ms: 0, speed: 0)
    expected_data = [0x2C, 0x81, 0x00, 0x00, 0x00, 0x00]
    actual_data = uart.writes.first[6, 6]
    assert_equal expected_data, actual_data
  end
```

- [ ] **Step 2: Run test, confirm failure**

```bash
bundle exec rake test TESTOPTS="--name=SCServoTest"
```

Delegate to haiku subagent. Expected: `NoMethodError: undefined method 'write_pos'`.

- [ ] **Step 3: Implement write_pos + helpers**

Add inside `class SCServo` in `mrbgems/picoruby-scservo/mrblib/scservo.rb`:

```ruby
  def write_pos(pos, time_ms: 0, speed: 0)
    pos_enc   = encode_signed(pos)
    time_enc  = encode_unsigned(time_ms)
    speed_enc = encode_unsigned(speed)
    data = [REG_GOAL_POS_L,
            pos_enc[0],   pos_enc[1],
            time_enc[0],  time_enc[1],
            speed_enc[0], speed_enc[1]]
    send_packet(INSTR_WRITE, data)
    drain_rx
    nil
  end

  private

  def send_packet(instr, params)
    length = params.length + 2   # instr + params + checksum, minus the LEN byte itself
    body = [@id, length, instr] + params
    sum = body.inject(0) { |acc, b| acc + b }
    cksum = (~sum) & 0xFF
    packet = HEADER + body + [cksum]
    @uart.write(packet)
  end

  def encode_unsigned(v)
    v &= 0xFFFF
    [v & 0xFF, (v >> 8) & 0xFF]
  end

  def encode_signed(v)
    # SCS uses sign-magnitude: bit 15 of the 16-bit value is the sign bit.
    if v < 0
      mag = (-v) & 0x7FFF
      [mag & 0xFF, ((mag >> 8) & 0x7F) | 0x80]
    else
      mag = v & 0x7FFF
      [mag & 0xFF, (mag >> 8) & 0x7F]
    end
  end

  def drain_rx
    # Stub for Task 5; do nothing until we add the real drain.
    nil
  end
```

- [ ] **Step 4: Run tests, verify pass**

```bash
bundle exec rake test TESTOPTS="--name=SCServoTest"
```

Delegate to haiku subagent. Expected: 4 PASS.

- [ ] **Step 5: Commit**

```bash
git add mrbgems/picoruby-scservo/mrblib/scservo.rb test/scservo_test.rb
git commit -m "feat(scservo): implement write_pos packet assembly with sign-magnitude encoding"
```

---

## Task 3: SCServo#read_pos with timeout

**Files:**
- Modify: `mrbgems/picoruby-scservo/mrblib/scservo.rb`
- Modify: `test/scservo_test.rb`

SCS ReadPos request packet:
```
0xFF 0xFF [ID] [LEN=4] [INSTR=0x02] [REG=0x38] [BYTES_TO_READ=2] [CKSUM]
```
Response packet:
```
0xFF 0xFF [ID] [LEN=4] [ERROR_FLAG] [pos_L pos_H] [CKSUM]
```

- [ ] **Step 1: Add failing tests**

Append to `test/scservo_test.rb`:

```ruby
  def test_read_pos_emits_request_packet
    uart = FakeUART.new
    # Pre-stage a valid response
    uart.read_queue << { bytes: [0xFF, 0xFF, 0x01, 0x04, 0x00, 0xF4, 0x01, 0x05] }
    servo = SCServo.new(uart, id: 1)
    servo.read_pos
    # request: ID=1, LEN=4, INSTR=2, REG=0x38, BYTES_TO_READ=2
    # sum=1+4+2+0x38+2 = 1+4+2+56+2 = 65 = 0x41 -> cksum=~0x41 & 0xFF = 0xBE
    expected_req = [0xFF, 0xFF, 0x01, 0x04, 0x02, 0x38, 0x02, 0xBE]
    assert_equal expected_req, uart.writes.first
  end

  def test_read_pos_returns_parsed_position
    uart = FakeUART.new
    # Response: pos = 0x01F4 = 500
    uart.read_queue << { bytes: [0xFF, 0xFF, 0x01, 0x04, 0x00, 0xF4, 0x01, 0x05] }
    servo = SCServo.new(uart, id: 1)
    assert_equal 500, servo.read_pos
  end

  def test_read_pos_decodes_negative
    uart = FakeUART.new
    # pos = 300 with sign bit -> [0x2C, 0x81], -> -300
    # Length and checksum recalc: ID=1, LEN=4, ERR=0, pos_L=0x2C, pos_H=0x81
    # sum=1+4+0+0x2C+0x81 = 1+4+44+129 = 178 = 0xB2 -> cksum=~0xB2 & 0xFF = 0x4D
    uart.read_queue << { bytes: [0xFF, 0xFF, 0x01, 0x04, 0x00, 0x2C, 0x81, 0x4D] }
    servo = SCServo.new(uart, id: 1)
    assert_equal(-300, servo.read_pos)
  end

  def test_read_pos_returns_nil_on_timeout
    uart = FakeUART.new
    uart.read_queue << :timeout
    servo = SCServo.new(uart, id: 1)
    assert_nil servo.read_pos
  end
```

- [ ] **Step 2: Run, confirm failure**

```bash
bundle exec rake test TESTOPTS="--name=SCServoTest"
```

Delegate to haiku subagent. Expected: 4 new failures (`undefined method read_pos`).

- [ ] **Step 3: Implement read_pos**

Add to `class SCServo` (move under the public section, before `private`):

```ruby
  def read_pos
    send_packet(INSTR_READ, [REG_PRESENT_POS_L, 0x02])
    raw = @uart.gets   # FakeUART returns nil on :timeout sentinel; on-device UART respects line_ending or timeout
    return nil if raw.nil? || raw.empty?
    bytes = raw.unpack('C*')
    # Expect: 0xFF 0xFF ID LEN ERR pos_L pos_H CKSUM (8 bytes)
    return nil if bytes.length < 8
    return nil unless bytes[0] == 0xFF && bytes[1] == 0xFF
    decode_signed(bytes[5], bytes[6])
  end

  private

  def decode_signed(lo, hi)
    if (hi & 0x80) != 0
      -(((hi & 0x7F) << 8) | lo)
    else
      ((hi & 0x7F) << 8) | lo
    end
  end
```

- [ ] **Step 4: Run, confirm pass**

```bash
bundle exec rake test TESTOPTS="--name=SCServoTest"
```

Delegate to haiku subagent. Expected: 8 PASS total.

- [ ] **Step 5: Commit**

```bash
git add mrbgems/picoruby-scservo/mrblib/scservo.rb test/scservo_test.rb
git commit -m "feat(scservo): implement read_pos with sign-magnitude decode and timeout"
```

---

## Task 4: SCServo#enable_torque + set_mode

**Files:**
- Modify: `mrbgems/picoruby-scservo/mrblib/scservo.rb`
- Modify: `test/scservo_test.rb`

- [ ] **Step 1: Add failing tests**

Append to `test/scservo_test.rb`:

```ruby
  def test_enable_torque_writes_reg_0x28_value_1
    uart = FakeUART.new
    SCServo.new(uart, id: 1).enable_torque
    # ID=1 LEN=4 INSTR=3 REG=0x28 DATA=1
    # sum=1+4+3+0x28+1 = 1+4+3+40+1 = 49 = 0x31 -> cksum=~0x31 & 0xFF = 0xCE
    expected = [0xFF, 0xFF, 0x01, 0x04, 0x03, 0x28, 0x01, 0xCE]
    assert_equal expected, uart.writes.first
  end

  def test_disable_torque_writes_reg_0x28_value_0
    uart = FakeUART.new
    SCServo.new(uart, id: 1).enable_torque(false)
    # sum=1+4+3+0x28+0 = 48 = 0x30 -> cksum = 0xCF
    expected = [0xFF, 0xFF, 0x01, 0x04, 0x03, 0x28, 0x00, 0xCF]
    assert_equal expected, uart.writes.first
  end

  def test_set_mode_position_writes_reg_0x21_value_0
    uart = FakeUART.new
    SCServo.new(uart, id: 1).set_mode(:position)
    # sum=1+4+3+0x21+0 = 1+4+3+33+0 = 41 = 0x29 -> cksum = 0xD6
    expected = [0xFF, 0xFF, 0x01, 0x04, 0x03, 0x21, 0x00, 0xD6]
    assert_equal expected, uart.writes.first
  end

  def test_set_mode_pwm_writes_reg_0x21_value_1
    uart = FakeUART.new
    SCServo.new(uart, id: 1).set_mode(:pwm)
    expected = [0xFF, 0xFF, 0x01, 0x04, 0x03, 0x21, 0x01, 0xD5]
    assert_equal expected, uart.writes.first
  end

  def test_set_mode_unknown_raises
    uart = FakeUART.new
    assert_raise(ArgumentError) do
      SCServo.new(uart, id: 1).set_mode(:wat)
    end
  end
```

- [ ] **Step 2: Run, confirm failure**

```bash
bundle exec rake test TESTOPTS="--name=SCServoTest"
```

Delegate to haiku subagent. Expected: 5 new failures.

- [ ] **Step 3: Implement enable_torque + set_mode**

Add to `class SCServo` in the public section:

```ruby
  def enable_torque(on = true)
    value = on ? 0x01 : 0x00
    send_packet(INSTR_WRITE, [REG_TORQUE, value])
    drain_rx
    nil
  end

  def set_mode(mode)
    value = case mode
            when :position then 0x00
            when :pwm      then 0x01
            else raise ArgumentError, "unknown mode: #{mode.inspect}"
            end
    send_packet(INSTR_WRITE, [REG_MODE, value])
    drain_rx
    nil
  end
```

- [ ] **Step 4: Run, confirm pass**

```bash
bundle exec rake test TESTOPTS="--name=SCServoTest"
```

Delegate to haiku subagent. Expected: 13 PASS total.

- [ ] **Step 5: Commit**

```bash
git add mrbgems/picoruby-scservo/mrblib/scservo.rb test/scservo_test.rb
git commit -m "feat(scservo): implement enable_torque and set_mode"
```

---

## Task 5: WritePos ACK drain (real drain_rx)

**Files:**
- Modify: `mrbgems/picoruby-scservo/mrblib/scservo.rb`
- Modify: `test/scservo_test.rb`
- Modify: `test/fake_uart.rb` (add a separate RX buffer to model "pending bytes after write")

The earlier tests pre-stage `read_queue` for `gets`. To model "WritePos returns a 6-byte status the next read should not see", we extend FakeUART with an `incoming_buffer` that `drain_rx` empties via `read(n, timeout_ms:)`.

- [ ] **Step 1: Extend FakeUART to model pending RX bytes**

Replace `test/fake_uart.rb` with:

```ruby
class FakeUART
  attr_reader :writes
  attr_accessor :read_queue
  attr_accessor :pending_rx   # bytes that drain_rx should consume

  def initialize
    @writes      = []
    @read_queue  = []
    @pending_rx  = []
  end

  def write(bytes)
    @writes << bytes
  end

  def read(n, timeout_ms: 0)
    return nil if @pending_rx.empty?
    take = [@pending_rx.length, n].min
    chunk = @pending_rx.shift(take)
    chunk
  end

  def gets
    item = @read_queue.shift
    return nil if item.nil? || item == :timeout
    item[:bytes].pack('C*')
  end
end
```

- [ ] **Step 2: Add failing test for drain after write_pos**

Append to `test/scservo_test.rb`:

```ruby
  def test_write_pos_drains_pending_writepos_ack_bytes
    uart = FakeUART.new
    # Simulate two servos' WritePos ACKs accumulated in the line buffer
    uart.pending_rx = [0xFF, 0xFF, 0x01, 0x02, 0x00, 0xFC,
                       0xFF, 0xFF, 0x02, 0x02, 0x00, 0xFB]
    servo = SCServo.new(uart, id: 1)
    servo.write_pos(500, time_ms: 0, speed: 0)
    # After write_pos, drain must have emptied pending_rx so subsequent read_pos
    # sees only the response we stage next.
    assert_empty uart.pending_rx
  end

  def test_read_pos_after_write_pos_isolates_response
    uart = FakeUART.new
    uart.pending_rx = [0xFF, 0xFF, 0x01, 0x02, 0x00, 0xFC]  # stale WritePos ACK
    uart.read_queue << { bytes: [0xFF, 0xFF, 0x01, 0x04, 0x00, 0xF4, 0x01, 0x05] }
    servo = SCServo.new(uart, id: 1)
    servo.write_pos(500, time_ms: 0, speed: 0)
    assert_equal 500, servo.read_pos
  end
```

- [ ] **Step 3: Run, confirm failure**

```bash
bundle exec rake test TESTOPTS="--name=SCServoTest"
```

Delegate to haiku subagent. Expected: 2 new failures (drain stub is a no-op so `pending_rx` stays non-empty).

- [ ] **Step 4: Implement real drain_rx**

Replace the no-op `drain_rx` in `mrbgems/picoruby-scservo/mrblib/scservo.rb` with:

```ruby
  def drain_rx
    # Best-effort consume of any pending WritePos status bytes so the next
    # read_pos does not misinterpret them. Sized for two servos * 6 bytes + margin.
    remaining = DRAIN_BUDGET_BYTES
    loop do
      chunk = @uart.read(remaining, timeout_ms: DRAIN_TIMEOUT_MS)
      break if chunk.nil? || chunk.empty?
      remaining -= chunk.length
      break if remaining <= 0
    end
    nil
  end
```

- [ ] **Step 5: Run, confirm pass**

```bash
bundle exec rake test TESTOPTS="--name=SCServoTest"
```

Delegate to haiku subagent. Expected: 15 PASS total.

- [ ] **Step 6: Commit**

```bash
git add mrbgems/picoruby-scservo/mrblib/scservo.rb test/scservo_test.rb test/fake_uart.rb
git commit -m "feat(scservo): drain WritePos status bytes to avoid stale RX"
```

---

## Task 6: StackchanApp::Head class with clamp + T-priority apply

**Files:**
- Modify: `mrbgems/picoruby-stackchan-protocol/examples/application.rb` (add `Head` module class, placed right after the `Face` module ends and before the `Dispatcher` class definition begins ~ line 195)
- Create: `test/head_test.rb`

- [ ] **Step 1: Add Head class to application.rb (between Face module and Dispatcher class)**

Locate the line that closes the `Face` module (search for the `end` that closes `module StackchanApp` — actually `Face` is a module nested under `StackchanApp`, so locate the last `end` of `module Face`). Insert immediately after that `end` and before `class Dispatcher`:

```ruby
  class Head
    YAW_RANGE   = (-1280..1280)
    PITCH_RANGE = (30..870)

    def initialize(yaw_servo, pitch_servo)
      @yaw   = yaw_servo
      @pitch = pitch_servo
    end

    def apply(frame)
      time_ms, speed = resolve_time_speed(frame)
      if frame.key?("Y")
        y = clamp(frame["Y"].to_i, YAW_RANGE)
        @yaw.write_pos(y, time_ms: time_ms, speed: speed)
      end
      if frame.key?("P")
        p = clamp(frame["P"].to_i, PITCH_RANGE)
        @pitch.write_pos(p, time_ms: time_ms, speed: speed)
      end
    end

    def read_actual
      { "Y_actual" => @yaw.read_pos, "P_actual" => @pitch.read_pos }
    end

    private

    def resolve_time_speed(frame)
      # T-priority: T present -> use T, else V if present, else both zero (max speed)
      if frame.key?("T")
        [frame["T"].to_i, 0]
      elsif frame.key?("V")
        [0, frame["V"].to_i]
      else
        [0, 0]
      end
    end

    def clamp(v, range)
      return range.first if v < range.first
      return range.last  if v > range.last
      v
    end
  end
```

- [ ] **Step 2: Create test/head_test.rb with failing tests**

```ruby
$LOAD_PATH.unshift(File.expand_path('.', __dir__))
require 'test_helper'

class HeadTest < Test::Unit::TestCase
  class FakeServo
    attr_reader :writes
    attr_accessor :next_read
    def initialize; @writes = []; @next_read = 0; end
    def write_pos(pos, time_ms:, speed:); @writes << [pos, time_ms, speed]; end
    def read_pos; @next_read; end
  end

  def setup
    @yaw   = FakeServo.new
    @pitch = FakeServo.new
    @head  = StackchanApp::Head.new(@yaw, @pitch)
  end

  def test_apply_with_Y_only_writes_yaw_holds_pitch
    @head.apply({ "Y" => "500" })
    assert_equal [[500, 0, 0]], @yaw.writes
    assert_empty @pitch.writes
  end

  def test_apply_with_P_only_writes_pitch_holds_yaw
    @head.apply({ "P" => "500" })
    assert_empty @yaw.writes
    assert_equal [[500, 0, 0]], @pitch.writes
  end

  def test_apply_with_T_overrides_V
    @head.apply({ "Y" => "100", "T" => "2000", "V" => "50" })
    assert_equal [[100, 2000, 0]], @yaw.writes
  end

  def test_apply_with_V_only_uses_velocity
    @head.apply({ "Y" => "100", "V" => "50" })
    assert_equal [[100, 0, 50]], @yaw.writes
  end

  def test_apply_with_neither_T_nor_V_means_max_speed
    @head.apply({ "Y" => "100" })
    assert_equal [[100, 0, 0]], @yaw.writes
  end

  def test_apply_clamps_yaw_above_max
    @head.apply({ "Y" => "9999" })
    assert_equal 1280, @yaw.writes.first[0]
  end

  def test_apply_clamps_yaw_below_min
    @head.apply({ "Y" => "-9999" })
    assert_equal(-1280, @yaw.writes.first[0])
  end

  def test_apply_clamps_pitch_above_max
    @head.apply({ "P" => "9999" })
    assert_equal 870, @pitch.writes.first[0]
  end

  def test_apply_clamps_pitch_below_min
    @head.apply({ "P" => "-100" })
    assert_equal 30, @pitch.writes.first[0]
  end

  def test_read_actual_returns_both_axes
    @yaw.next_read   = 123
    @pitch.next_read = 456
    assert_equal({ "Y_actual" => 123, "P_actual" => 456 }, @head.read_actual)
  end

  def test_read_actual_propagates_nil
    @yaw.next_read   = nil
    @pitch.next_read = 500
    assert_equal({ "Y_actual" => nil, "P_actual" => 500 }, @head.read_actual)
  end
end
```

- [ ] **Step 3: Run, confirm pass**

```bash
bundle exec rake test TESTOPTS="--name=HeadTest"
```

Delegate to haiku subagent. Expected: 11 PASS (since Step 1 already added the Head class). If failures appear, the Head class was placed incorrectly — verify line position.

- [ ] **Step 4: Run the full suite to catch regressions**

```bash
bundle exec rake test
```

Delegate to haiku subagent. Expected: existing 19 + 15 (SCServo) + 11 (Head) = 45 PASS, 0 omit.

- [ ] **Step 5: Commit**

```bash
git add mrbgems/picoruby-stackchan-protocol/examples/application.rb test/head_test.rb
git commit -m "feat(head): add StackchanApp::Head with clamp and T-priority/V-fallback"
```

---

## Task 7: Dispatcher Y/P/V/T branch + extra detail frame

**Files:**
- Modify: `mrbgems/picoruby-stackchan-protocol/examples/application.rb` (Dispatcher class)
- Create: `test/dispatcher_servo_test.rb`

The Dispatcher's `handle` already writes a single byte ACK to `@stdout`. We extend the same `@stdout` channel for the detail frame (the on-device wiring forwards `@stdout` writes to NUS notify regardless of length).

- [ ] **Step 1: Create failing test/dispatcher_servo_test.rb**

```ruby
$LOAD_PATH.unshift(File.expand_path('.', __dir__))
require 'test_helper'

class DispatcherServoTest < Test::Unit::TestCase
  class FakeServo
    attr_reader :writes
    attr_accessor :next_read
    def initialize; @writes = []; @next_read = 0; end
    def write_pos(pos, time_ms:, speed:); @writes << [pos, time_ms, speed]; end
    def read_pos; @next_read; end
  end

  class MiniSink
    attr_reader :writes
    def initialize; @writes = []; end
    def write(b); @writes << b; end
  end

  def setup
    @display = FakeDisplay.new
    @led     = FakeLed.new
    @stdout  = MiniSink.new
    @yaw_servo   = FakeServo.new
    @pitch_servo = FakeServo.new
    @head    = StackchanApp::Head.new(@yaw_servo, @pitch_servo)
    @disp    = StackchanApp::Dispatcher.new(
      display: @display, led: @led, stdout: @stdout, head: @head
    )
  end

  def test_Y_frame_routes_to_yaw
    @yaw_servo.next_read = 498
    @pitch_servo.next_read = 500
    @disp.handle({ "Y" => "-300", "P" => "500", "T" => "2000" })
    assert_equal [[-300, 2000, 0]], @yaw_servo.writes
    assert_equal [[500,  2000, 0]], @pitch_servo.writes
  end

  def test_servo_frame_emits_ack_byte_then_detail_frame
    @yaw_servo.next_read = 498
    @pitch_servo.next_read = 500
    @disp.handle({ "Y" => "-300", "P" => "500" })
    # 1st write: ACK byte ".", 2nd write: detail frame "<Y_actual:498,P_actual:500>\n"
    assert_equal ".", @stdout.writes[0]
    assert_equal "<Y_actual:498,P_actual:500>\n", @stdout.writes[1]
  end

  def test_servo_frame_with_nil_read_emits_error_frame
    @yaw_servo.next_read   = nil
    @pitch_servo.next_read = 500
    @disp.handle({ "Y" => "-300", "P" => "500" })
    assert_equal ".", @stdout.writes[0]
    assert_equal "<ERROR:servo_timeout,axis:yaw>\n", @stdout.writes[1]
  end

  def test_servo_frame_with_both_nil_axis_is_both
    @yaw_servo.next_read   = nil
    @pitch_servo.next_read = nil
    @disp.handle({ "Y" => "-300", "P" => "500" })
    assert_equal "<ERROR:servo_timeout,axis:both>\n", @stdout.writes[1]
  end

  def test_servo_frame_with_only_yaw_specified_only_yaw_axis_in_error
    @yaw_servo.next_read   = nil
    @pitch_servo.next_read = 500   # but pitch wasn't asked
    @disp.handle({ "Y" => "-300" })
    # Only Y is in the frame; pitch wasn't requested even if its read_pos is fine
    assert_equal "<ERROR:servo_timeout,axis:yaw>\n", @stdout.writes[1]
  end

  def test_mixed_face_and_servo_frame_dispatches_both
    @yaw_servo.next_read = 100
    @pitch_servo.next_read = 200
    @disp.handle({ "F" => "0", "Y" => "100", "P" => "200" })
    assert @display.calls.any? { |c| c.first == :draw_ellipse }
    assert_equal [[100, 0, 0]], @yaw_servo.writes
    assert_equal [[200, 0, 0]], @pitch_servo.writes
  end

  def test_dispatcher_without_head_returns_unavailable
    disp = StackchanApp::Dispatcher.new(
      display: @display, led: @led, stdout: @stdout, head: nil
    )
    disp.handle({ "Y" => "100" })
    # ACK still ".", but detail frame indicates unavailable
    assert_equal ".", @stdout.writes[0]
    assert_equal "<ERROR:servo_unavailable>\n", @stdout.writes[1]
  end
end
```

- [ ] **Step 2: Run, confirm failure**

```bash
bundle exec rake test TESTOPTS="--name=DispatcherServoTest"
```

Delegate to haiku subagent. Expected: 7 failures (Dispatcher doesn't accept `head:` kwarg and doesn't have a head branch).

- [ ] **Step 3: Modify Dispatcher in application.rb**

Find `def initialize(display:, led:, stdout: $stdout)` (around line 225) and replace with:

```ruby
    def initialize(display:, led:, stdout: $stdout, head: nil)
      @display = display
      @led     = led
      @stdout  = stdout
      @head    = head
      @current_face_class = Face::Neutral
    end
```

Find the `handle` method (around line 232) and replace with:

```ruby
    def handle(frame)
      attempts = []
      attempts << handle_face(frame) if frame.key?("F")
      attempts << handle_led(frame)  if frame.key?("L")
      servo_present = frame.key?("Y") || frame.key?("P") || frame.key?("V") || frame.key?("T")
      attempts << handle_head(frame) if servo_present
      success = !attempts.empty? && attempts.all? { |ok| ok }
      @stdout.write(success ? ACK_BYTE : ERROR_BYTE)
      emit_servo_detail(frame) if servo_present
    rescue => e
      log_error(e)
      @stdout.write(ERROR_BYTE)
    end
```

Add inside the `private` section (after `handle_led`):

```ruby
    def handle_head(frame)
      return false if @head.nil?
      @head.apply(frame)
      true
    end

    def emit_servo_detail(frame)
      if @head.nil?
        @stdout.write("<ERROR:servo_unavailable>\n")
        return
      end
      actual = @head.read_actual
      failed = []
      failed << "yaw"   if actual["Y_actual"].nil? && frame.key?("Y")
      failed << "pitch" if actual["P_actual"].nil? && frame.key?("P")
      if failed.any?
        axis = failed.size == 2 ? "both" : failed.first
        @stdout.write("<ERROR:servo_timeout,axis:#{axis}>\n")
      else
        y = frame.key?("Y") ? actual["Y_actual"] : nil
        p = frame.key?("P") ? actual["P_actual"] : nil
        parts = []
        parts << "Y_actual:#{y}" if y
        parts << "P_actual:#{p}" if p
        # If only T or V given (no Y/P), still report both axes for visibility
        if parts.empty?
          parts << "Y_actual:#{actual['Y_actual']}"
          parts << "P_actual:#{actual['P_actual']}"
        end
        @stdout.write("<#{parts.join(',')}>\n")
      end
    end
```

- [ ] **Step 4: Run, confirm pass**

```bash
bundle exec rake test TESTOPTS="--name=DispatcherServoTest"
```

Delegate to haiku subagent. Expected: 7 PASS.

- [ ] **Step 5: Run full suite for regressions**

```bash
bundle exec rake test
```

Delegate to haiku subagent. Expected: existing 19 + 15 (SCServo) + 11 (Head) + 7 (DispatcherServo) = 52 PASS, 0 omit.

- [ ] **Step 6: Commit**

```bash
git add mrbgems/picoruby-stackchan-protocol/examples/application.rb test/dispatcher_servo_test.rb
git commit -m "feat(dispatcher): add Y/P/V/T branch with ACK byte + detail frame"
```

---

## Task 8: application.rb cold-boot servo init + StackChanApp wiring

**Files:**
- Modify: `mrbgems/picoruby-stackchan-protocol/examples/application.rb`

The cold-boot block ends with `sleep_ms 3000` (line ~361, BTstack yield). The servo subsystem initializes between LED init and the `sleep_ms 3000` so the yield happens after the SCS bus is up.

- [ ] **Step 1: Read the existing cold-boot tail to identify insertion point**

Run:

```bash
grep -n "sleep_ms 3000" /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/mrbgems/picoruby-stackchan-protocol/examples/application.rb
```

Expected output: a single line number around 361. Confirm the line above is the LED init / Face::Neutral.draw block.

- [ ] **Step 2: Insert servo init block immediately before `sleep_ms 3000`**

In `mrbgems/picoruby-stackchan-protocol/examples/application.rb`, find the `sleep_ms 3000` line. Insert the following block immediately above it:

```ruby
# Phase B: servo bring-up. Failure must NOT block face/LED — keep @head=nil so
# Dispatcher can return <ERROR:servo_unavailable> while Phase A features stay live.
@head = nil
begin
  servo_uart = UART.new(unit: :UART1, txd_pin: 7, rxd_pin: 6, baudrate: 1_000_000)
  yaw_servo   = SCServo.new(servo_uart, id: 1)
  pitch_servo = SCServo.new(servo_uart, id: 2)
  yaw_servo.enable_torque
  pitch_servo.enable_torque
  @head = StackchanApp::Head.new(yaw_servo, pitch_servo)
  puts "[boot] servo init OK"
rescue => e
  puts "[boot] servo init failed: #{e.class}: #{e.message}"
end
```

- [ ] **Step 3: Wire @head through StackChanApp into Dispatcher**

Find the `StackChanApp` class definition (around line 365). Inside its `initialize` method, locate where `@dispatcher` is built (search for `Dispatcher.new`) and update the call to pass `head:`:

```ruby
@dispatcher = StackchanApp::Dispatcher.new(
  display: @display,
  led:     @led,
  stdout:  ...,         # whatever stdout is currently passed; leave unchanged
  head:    @head,
)
```

Set `@head` before that line by reading from the outer scope (top-level instance variable propagates if app uses top-level instance vars; if not, read it via `head: $head` or pass through `StackChanApp.new(head: @head)`). The exact wiring depends on the current `StackChanApp.new(...)` signature.

**To verify the current signature**, run:

```bash
grep -n "StackChanApp.new\|def initialize" /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/mrbgems/picoruby-stackchan-protocol/examples/application.rb | head -20
```

Adjust the wiring approach based on output:
- If `StackChanApp.new(display:, led:, ...)` already takes a kwarg list, add `head:`
- If `StackChanApp` reads outer-scope `@display` directly, do the same for `@head`

Pick the approach that matches the existing pattern. Do not introduce a new style.

- [ ] **Step 4: Verify host tests still pass (no regression from class-shape change)**

```bash
bundle exec rake test
```

Delegate to haiku subagent. Expected: 52 PASS, 0 omit (Step 1-3 changes are outside class definitions / use `UART` which is stubbed; the prism extract should still load `Head` and `Dispatcher` correctly).

If the count drops, the inserted block likely broke the class extract. Check that:
- The `@head = nil` line and the `begin..rescue` block sit at top-level (outside any class)
- The `Head` class still parses cleanly (closing `end` is intact)

- [ ] **Step 5: Commit**

```bash
git add mrbgems/picoruby-stackchan-protocol/examples/application.rb
git commit -m "feat(boot): cold-boot servo init with degradation rescue + Dispatcher wiring"
```

---

## Task 9: Add picoruby-scservo to R2P2-ESP32 build_config

**Files:**
- Modify: `/Users/bash/dev/src/github.com/bash0C7/R2P2-ESP32/components/picoruby-esp32/build_config/xtensa-esp-picoruby.rb`

- [ ] **Step 1: Read the existing `conf.gem` block to find a sibling line for insertion**

```bash
grep -n "conf.gem.*stackchan-picoruby" /Users/bash/dev/src/github.com/bash0C7/R2P2-ESP32/components/picoruby-esp32/build_config/xtensa-esp-picoruby.rb
```

Expected output: a line like `conf.gem gemdir: '/Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/mrbgems/picoruby-stackchan-protocol'`.

- [ ] **Step 2: Add new gem line**

Immediately after the matching `picoruby-stackchan-protocol` conf.gem line, add:

```ruby
  conf.gem gemdir: '/Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/mrbgems/picoruby-scservo'
```

- [ ] **Step 3: Commit build_config change**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/R2P2-ESP32
git add components/picoruby-esp32/build_config/xtensa-esp-picoruby.rb
git commit -m "build: add picoruby-scservo to stackchan target build"
```

(Note: this commit lands in the R2P2-ESP32 repo, not stackchan-picoruby. R2P2-ESP32 origin is `bash0C7/R2P2-ESP32` so per memory `feedback_local_commit_autonomy_bash0c7_only` the autonomy applies.)

- [ ] **Step 4: Verify build_config syntax**

```bash
ruby -c /Users/bash/dev/src/github.com/bash0C7/R2P2-ESP32/components/picoruby-esp32/build_config/xtensa-esp-picoruby.rb
```

Expected: `Syntax OK`.

---

## Task 10: Firmware full rebuild + boot-verify

**Files:** (no file changes — this is a deploy+verify step)

- [ ] **Step 1: Invoke full rebuild via skill**

Use the `stackchan-device-full-rebuild` skill (chained `r2p2:full_rebuild` rake task: build_flash → wipe → upload_appmrb → reset, ~7 min). This task wipes storage and re-uploads `application.rb` as `/home/app.mrb`.

Expected: skill returns "PASS" + boot log shows `[boot] servo init OK` (or `failed: ...` if servo hardware not attached, which is acceptable — degradation works).

- [ ] **Step 2: Run boot-verify to confirm no Guru / no early panic**

Use the `stackchan-device-boot-verify` skill. This captures a fresh boot log and runs `crash-analyze` on any panic.

Expected: skill returns "PASS, no panic". The log should contain either `[boot] servo init OK` or `[boot] servo init failed: ...` depending on hardware presence — both are acceptable cold-boot states.

- [ ] **Step 3: Check BLE advertising still works**

Use `bin/capture-with-pty 30 /tmp/stackchan-picoruby-debug/boot.log bundle exec rake r2p2:monitor` and look for the advertisement-started log line (Phase A established).

Expected: `gap_advertisements_enable(1)` line present. If missing, the BTstack yield got broken — review Task 8 insertion point.

- [ ] **Step 4: Commit any incidental notes (skip if none)**

If `[boot] servo init failed: ...` appears with hardware attached, that is a real bug to investigate before continuing. Don't commit anything — branch back to debug.

If `[boot] servo init OK` appears, no commit needed for this task.

- [ ] **Step 5: Boot-failure regression test (deliberate bad GPIO)**

Verify the degradation path from spec §5.4. Edit `application.rb` to temporarily set `txd_pin: 99` (a nonexistent GPIO) in the servo init block:

```ruby
servo_uart = UART.new(unit: :UART1, txd_pin: 99, rxd_pin: 6, baudrate: 1_000_000)
```

Deploy via `/stackchan-device-deploy-app` and run `/stackchan-device-boot-verify`.

Expected:
- Boot completes (no Guru Meditation)
- Log line `[boot] servo init failed: ...` appears
- BLE advertising still works (Phase A face / LED unaffected)
- Sending `<Y:0,P:450>` via `stackchan-ble-control servo --yaw 0 --pitch 450` returns the detail frame `<ERROR:servo_unavailable>` after the byte ACK

Then **revert the change** (set `txd_pin: 7` back) and redeploy:

```bash
# Edit application.rb to restore txd_pin: 7
/stackchan-device-deploy-app
/stackchan-device-boot-verify   # must show [boot] servo init OK again
```

No commit for the temporary edit. The verification result goes into the Phase B memory entry at Task 16.

---

## Task 11: Mac side — SendBuilder + FrameCodec for head

**Files:**
- Modify: `pc/stackchan-ble-client/lib/stackchan_ble_client/send_builder.rb`
- Modify: `pc/stackchan-ble-client/lib/stackchan_ble_client/frame_codec.rb`

- [ ] **Step 1: Inspect existing Mac-side test layout to choose test file location**

```bash
ls /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/pc/stackchan-ble-client/
find /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/pc/stackchan-ble-client -name '*_test.rb' -o -name '*_spec.rb' | head
```

Look at the output and follow the established naming. If no test files exist for `send_builder.rb` / `frame_codec.rb`, create new ones following the project's existing convention.

- [ ] **Step 2: Add failing tests**

If the convention is Test::Unit, create or modify the appropriate test file under `pc/stackchan-ble-client/test/` with:

```ruby
require 'test_helper'
require 'stackchan_ble_client/frame_codec'

class FrameCodecHeadTest < Test::Unit::TestCase
  def test_encode_head_all_axes_and_time
    out = StackchanBleClient::FrameCodec.encode_head(
      yaw: -300, pitch: 500, time_ms: 2000, velocity: nil
    )
    assert_equal "<Y:-300,P:500,T:2000>\n", out
  end

  def test_encode_head_with_velocity
    out = StackchanBleClient::FrameCodec.encode_head(
      yaw: 100, pitch: nil, time_ms: nil, velocity: 50
    )
    assert_equal "<Y:100,V:50>\n", out
  end

  def test_encode_head_yaw_only_no_time_no_velocity
    out = StackchanBleClient::FrameCodec.encode_head(
      yaw: 0, pitch: nil, time_ms: nil, velocity: nil
    )
    assert_equal "<Y:0>\n", out
  end

  def test_encode_head_pitch_only
    out = StackchanBleClient::FrameCodec.encode_head(
      yaw: nil, pitch: 500, time_ms: nil, velocity: nil
    )
    assert_equal "<P:500>\n", out
  end

  def test_encode_head_neither_axis_raises
    assert_raise(ArgumentError) do
      StackchanBleClient::FrameCodec.encode_head(
        yaw: nil, pitch: nil, time_ms: 100, velocity: nil
      )
    end
  end
end
```

- [ ] **Step 3: Run, confirm failure**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/pc/stackchan-ble-client
bundle exec rake test 2>&1 | tail -30
```

Delegate the rake invocation to a haiku subagent. Expected: failures referencing `encode_head` not defined.

- [ ] **Step 4: Implement FrameCodec.encode_head**

In `pc/stackchan-ble-client/lib/stackchan_ble_client/frame_codec.rb`, add inside `module FrameCodec` (above `def parse_ack`):

```ruby
    def encode_head(yaw:, pitch:, time_ms:, velocity:)
      if yaw.nil? && pitch.nil?
        raise ArgumentError, "encode_head requires at least one of yaw / pitch"
      end
      pairs = {}
      pairs["Y"] = yaw.to_s   if yaw
      pairs["P"] = pitch.to_s if pitch
      pairs["T"] = time_ms.to_s  if time_ms
      pairs["V"] = velocity.to_s if velocity && !time_ms
      encode_pairs(pairs)
    end
```

- [ ] **Step 5: Implement SendBuilder#head**

In `pc/stackchan-ble-client/lib/stackchan_ble_client/send_builder.rb`, add inside `class SendBuilder`:

```ruby
    def head(yaw: nil, pitch: nil, time_ms: nil, velocity: nil)
      record(:head, {
        kind: :head, yaw: yaw, pitch: pitch, time_ms: time_ms, velocity: velocity,
      })
    end
```

And add a `when :head` branch inside the `encode` private method:

```ruby
      when :head
        FrameCodec.encode_head(
          yaw: cmd[:yaw], pitch: cmd[:pitch],
          time_ms: cmd[:time_ms], velocity: cmd[:velocity],
        )
```

- [ ] **Step 6: Run, confirm pass**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/pc/stackchan-ble-client
bundle exec rake test
```

Delegate to haiku subagent. Expected: 5 new PASS for FrameCodecHeadTest plus existing tests still PASS.

- [ ] **Step 7: Commit**

```bash
git add pc/stackchan-ble-client/lib/stackchan_ble_client/frame_codec.rb pc/stackchan-ble-client/lib/stackchan_ble_client/send_builder.rb pc/stackchan-ble-client/test/
git commit -m "feat(ble-client): add head frame encoder and SendBuilder#head"
```

---

## Task 12: Mac side — stackchan-ble-control servo subcommand

**Files:**
- Modify: `pc/stackchan-ble-client/exe/stackchan-ble-control`

- [ ] **Step 1: Add `servo` subcommand**

In `pc/stackchan-ble-client/exe/stackchan-ble-control`, add a `servo` case to the `case command ... end` block (between `combo` and `raw`):

```ruby
  when "servo"
    yaw_str    = nil
    pitch_str  = nil
    time_str   = nil
    velocity_s = nil
    while ARGV.first&.start_with?("--")
      flag = ARGV.shift
      val  = ARGV.shift
      case flag
      when "--yaw"      then yaw_str    = val
      when "--pitch"    then pitch_str  = val
      when "--time"     then time_str   = val
      when "--velocity" then velocity_s = val
      else abort "error: unknown servo flag #{flag}"
      end
    end
    abort "error: servo requires at least one of --yaw / --pitch" if yaw_str.nil? && pitch_str.nil?
    yaw      = yaw_str   && Integer(yaw_str, 10)
    pitch    = pitch_str && Integer(pitch_str, 10)
    time_ms  = time_str  && Integer(time_str, 10)
    velocity = velocity_s && Integer(velocity_s, 10)
    client.send do |s|
      s.head(yaw: yaw, pitch: pitch, time_ms: time_ms, velocity: velocity)
    end
```

- [ ] **Step 2: Update the abort message at line 37 to include `servo`**

```ruby
abort "error: command required (face / led / led-rgb / led-hsb / combo / servo / raw)" unless command
```

- [ ] **Step 3: Verify CLI parses correctly (smoke test, no BLE)**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/pc/stackchan-ble-client
bundle exec exe/stackchan-ble-control servo 2>&1 | head -5
```

Expected: `error: servo requires at least one of --yaw / --pitch` (the abort kicks in before any BLE call).

```bash
bundle exec exe/stackchan-ble-control servo --yaw foo 2>&1 | head -5
```

Expected: `Integer()` raises `invalid value for Integer()` and the wrapping rescue prints `[FAIL] ... domain=uncaught`. This is acceptable behaviour for a malformed CLI input.

- [ ] **Step 4: Commit**

```bash
git add pc/stackchan-ble-client/exe/stackchan-ble-control
git commit -m "feat(ble-control): add servo subcommand with --yaw/--pitch/--time/--velocity"
```

---

## Task 13: stackchan-notifier servo hook

**Files:**
- Modify: `pc/stackchan-notifier/lib/stackchan_notifier/worker.rb`

- [ ] **Step 1: Read current worker.rb to understand the case structure**

```bash
grep -n "case tuple\|when :" /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/pc/stackchan-notifier/lib/stackchan_notifier/worker.rb
```

Identify the existing `case` block in `handle_tuple` and the existing `:notify` (or equivalent) case branch shape.

- [ ] **Step 2: Inspect the existing :notify case body to learn the pattern**

```bash
grep -n -A 20 "when :notify" /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/pc/stackchan-notifier/lib/stackchan_notifier/worker.rb
```

Note how the existing case dispatches to BLE actions (likely shelling out to `stackchan-ble-control` or using `StackchanBleClient` directly).

- [ ] **Step 3: Add `:servo` case branch following the same pattern**

In `pc/stackchan-notifier/lib/stackchan_notifier/worker.rb`, add inside the `handle_tuple` case (matching the existing notify pattern, e.g. via shelling out to ble-control):

```ruby
      when :servo
        # tuple shape: [:servo, { yaw: int_or_nil, pitch: int_or_nil, time_ms: int_or_nil, velocity: int_or_nil, name_prefix: str_or_nil }]
        params = tuple[1] || {}
        args = ["servo"]
        args.concat(["--yaw",    params[:yaw].to_s])      if params[:yaw]
        args.concat(["--pitch",  params[:pitch].to_s])    if params[:pitch]
        args.concat(["--time",   params[:time_ms].to_s])  if params[:time_ms]
        args.concat(["--velocity", params[:velocity].to_s]) if params[:velocity]
        cli_args = []
        cli_args.concat(["--name-prefix", params[:name_prefix]]) if params[:name_prefix]
        cli_args.concat(args)
        # Match the existing :notify branch's invocation idiom (system / spawn / inline client)
        invoke_ble_control(cli_args)
```

If the existing pattern uses a helper method (e.g. `invoke_ble_control`), reuse it. If the existing pattern uses inline `system` or `Open3`, mirror that exactly — don't introduce a new style.

- [ ] **Step 4: Add a unit test if the notifier has a test directory**

```bash
ls /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/pc/stackchan-notifier/test/ 2>/dev/null || echo "no test dir"
```

If there's a `test/` directory, add `pc/stackchan-notifier/test/servo_dispatch_test.rb` following the existing test pattern. The test should drive `Worker#handle_tuple` with `[:servo, { yaw: -300, pitch: 500, time_ms: 2000 }]` and assert that the BLE-control invocation receives the expected argv (using whatever mock/stub idiom the existing tests use). If no `test/` directory exists, skip the unit test — the integration will be covered by Task 14's HITL.

- [ ] **Step 5: Run notifier tests if they exist**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/pc/stackchan-notifier
bundle exec rake test 2>/dev/null || echo "no rake test"
```

Delegate to haiku subagent. Expected: PASS if tests exist; otherwise skip.

- [ ] **Step 6: Commit**

```bash
git add pc/stackchan-notifier/lib/stackchan_notifier/worker.rb pc/stackchan-notifier/test/
git commit -m "feat(notifier): add :servo tuple dispatch for hook-driven servo commands"
```

---

## Task 14: stackchan-device-servo-verify skill

**Files:**
- Create: `.claude/skills/stackchan-device-servo-verify/SKILL.md`

This is the Phase B counterpart to `stackchan-device-face-verify`. Inspect that skill first as the template.

- [ ] **Step 1: Read face-verify skill as template**

```bash
cat /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/.claude/skills/stackchan-device-face-verify/SKILL.md
```

- [ ] **Step 2: Create the servo-verify skill**

Create `.claude/skills/stackchan-device-servo-verify/SKILL.md`:

```markdown
---
name: stackchan-device-servo-verify
description: Servo regression — drive yaw/pitch to fixed targets via BLE NUS, parse the device-side detail frame (Y_actual / P_actual), assert |actual - target| within tolerance. Phase B counterpart to face-verify. ~30 s.
---

# stackchan-device-servo-verify

## When to use

After a deploy that touched servo code (picoruby-scservo / Head / Dispatcher head branch / cold-boot servo init) or before merging to verify Phase B regression-free.

## What it does

1. Sends 5 fixed servo frames over BLE NUS via `stackchan-ble-control servo`:
   - center: `--yaw 0 --pitch 450 --time 0`
   - right:  `--yaw 1000 --pitch 450 --time 0`
   - left:   `--yaw -1000 --pitch 450 --time 0`
   - down:   `--yaw 0 --pitch 100 --time 0`
   - up:     `--yaw 0 --pitch 800 --time 0`
2. For each, waits 250 ms then sends the same frame again to provoke a fresh `<Y_actual:..,P_actual:..>` response (the first emission is in motion; the second after settling reads the actual stopped position).
3. Parses the detail frame, asserts `|Y_actual - target| <= 8` and `|P_actual - target| <= 8` (SCS encoder noise floor allows ~5 units; 8 is a safety margin).
4. Returns PASS if all 5 frames pass, FAIL otherwise.

## Inputs / outputs

- Input: device must be powered, advertising, within BLE range. No CLI args.
- Output (subagent-friendly):
  - PASS line per target: `[PASS] center yaw=2 pitch=448`
  - FAIL line: `[FAIL] left yaw=-993 pitch=448 reason=yaw|y_target=-1000|delta=7`
  - Final summary line: `RESULT: 5/5 PASS` or `RESULT: 3/5 PASS — left/up FAIL`
  - Exit code 0 on all PASS, non-zero otherwise.

## Implementation

The skill is realized as a Ruby script `bin/servo-verify` invoked here. The script uses `StackchanBleClient::Client` directly to send each frame and capture both the byte ACK and the detail frame notify, then parses Y_actual/P_actual via a regex `\AY_actual:(-?\d+),P_actual:(-?\d+)\z`.

(The bin script itself is implemented as part of Task 14 Step 3 below — keep it inside this skill task to avoid scattering Phase B work.)

## Out of scope

- Velocity / time-based motion accuracy (Phase B treats T/V as "command accepted" not "movement completed"; verifying smooth interpolation belongs to HITL or Phase C+)
- Multiple servos beyond yaw + pitch (Phase B targets two)
- Stress / longevity tests
```

- [ ] **Step 3: Create the bin/servo-verify script**

Create `pc/stackchan-ble-client/exe/servo-verify`:

```ruby
#!/usr/bin/env ruby
require "bundler/setup"
require "stackchan_ble_client"

EXIT_OK = 0
EXIT_FAIL = 1

TOLERANCE = 8
TARGETS = [
  { name: "center", yaw:    0, pitch: 450 },
  { name: "right",  yaw: 1000, pitch: 450 },
  { name: "left",   yaw:-1000, pitch: 450 },
  { name: "down",   yaw:    0, pitch: 100 },
  { name: "up",     yaw:    0, pitch: 800 },
]

device_name = ENV.fetch("BLE_DEVICE_NAME", "StackChan-PicoRuby")
name_prefix = ENV["BLE_NAME_PREFIX"]
client = StackchanBleClient::Client.new(device_name: device_name, name_prefix: name_prefix)

passed = []
failed = []

begin
  client.connect

  TARGETS.each do |t|
    # First frame to start motion
    client.send { |s| s.head(yaw: t[:yaw], pitch: t[:pitch], time_ms: 0, velocity: nil) }
    sleep 0.25
    # Second frame to read settled position via detail frame
    detail = client.raw_send_and_capture_detail("<Y:#{t[:yaw]},P:#{t[:pitch]}>\n", timeout: 2.0)
    if (m = detail&.match(/\AY_actual:(-?\d+),P_actual:(-?\d+)/))
      y_actual = m[1].to_i
      p_actual = m[2].to_i
      dy = (y_actual - t[:yaw]).abs
      dp = (p_actual - t[:pitch]).abs
      if dy <= TOLERANCE && dp <= TOLERANCE
        puts "[PASS] #{t[:name]} yaw=#{y_actual} pitch=#{p_actual}"
        passed << t[:name]
      else
        puts "[FAIL] #{t[:name]} yaw=#{y_actual} pitch=#{p_actual} reason=yaw|y_target=#{t[:yaw]}|delta=#{dy} pitch|p_target=#{t[:pitch]}|delta=#{dp}"
        failed << t[:name]
      end
    else
      puts "[FAIL] #{t[:name]} reason=no_detail_frame raw=#{detail.inspect}"
      failed << t[:name]
    end
  end
ensure
  client.disconnect rescue nil
end

if failed.empty?
  puts "RESULT: #{passed.length}/#{TARGETS.length} PASS"
  exit EXIT_OK
else
  puts "RESULT: #{passed.length}/#{TARGETS.length} PASS — #{failed.join('/')} FAIL"
  exit EXIT_FAIL
end
```

- [ ] **Step 4: Inspect existing Client class notify handling**

Read these files in full to understand how notify bytes arrive at the host and how `raw_send` already handles the byte-ACK case:

```bash
ls /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/pc/stackchan-ble-client/lib/stackchan_ble_client/
grep -n "def raw_send\|def send\|notify\|on_notif\|@ack_queue\|@notify_queue" /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/pc/stackchan-ble-client/lib/stackchan_ble_client/*.rb
```

The output reveals whether notify dispatch is callback-based or queue-based, and whether multiple notifies for one write are already aggregated. Phase A's ACK byte path will be the model.

- [ ] **Step 5: Add `raw_send_and_capture_detail` helper to Client**

Add the method to the same file that defines `raw_send` (typically `client.rb`). The method must:

1. Send the raw frame via the existing transport (reuse `raw_send` body or call it directly)
2. Wait for **two** notifies: the byte ACK (`.` or `?`) **and** the detail frame (starts with `<`, ends with `\n`)
3. Return the detail frame string (with trailing `\n` stripped); return `nil` if no detail frame arrives within `timeout` seconds

Skeleton (adapt to the queue/callback shape revealed in Step 4):

```ruby
    # Returns the detail frame string (e.g. "<Y_actual:498,P_actual:500>") or nil on timeout.
    def raw_send_and_capture_detail(frame, timeout: 2.0)
      detail = nil
      # Hook the existing notify dispatcher to capture frames starting with '<'
      notify_listener = ->(bytes) {
        next if detail
        str = bytes.is_a?(String) ? bytes : bytes.pack('C*')
        detail = str.chomp if str.start_with?("<")
      }
      attach_notify_listener(notify_listener)
      begin
        raw_send(frame)
        deadline = Time.now + timeout
        until detail || Time.now > deadline
          sleep 0.05
        end
        detail
      ensure
        detach_notify_listener(notify_listener)
      end
    end
```

If the existing dispatcher does not expose attach/detach hooks, either:
- (a) Extend it minimally to expose them (preferred, isolated change), or
- (b) Use a class-level `@notify_log` array that the existing notify handler appends to, and have this method drain it

Pick (a) if the existing handler is small (~30 lines or less); (b) if it's larger and the change surface should stay minimal.

- [ ] **Step 6: Make the script executable and smoke-run**

```bash
chmod +x pc/stackchan-ble-client/exe/servo-verify
bundle exec exe/servo-verify 2>&1 | head -20
```

Expected: with the device powered: `RESULT: 5/5 PASS` (or any FAIL pointing to a real defect to investigate).

If the device is not powered or out of range, expect a BLE connect failure within ~30 s.

- [ ] **Step 7: Commit**

```bash
git add .claude/skills/stackchan-device-servo-verify/SKILL.md pc/stackchan-ble-client/exe/servo-verify pc/stackchan-ble-client/lib/stackchan_ble_client/
git commit -m "feat(skill): add stackchan-device-servo-verify with 5-target tolerance check"
```

---

## Task 15: HITL checklist + initial human pass

**Files:**
- Create: `docs/superpowers/handoff/phase-b-hitl-checklist.md`

- [ ] **Step 1: Create the checklist template**

```markdown
# Phase B Servo HITL Checklist

## Procedure

After running `stackchan-device-servo-verify` (Task 14) and getting `RESULT: 5/5 PASS`, perform the following with the StackChan in view:

1. `bundle exec exe/stackchan-ble-control servo --yaw 0 --pitch 450`
   - Expected: head returns to centered, neutral pose
2. `bundle exec exe/stackchan-ble-control servo --yaw -1280 --pitch 450 --time 3000`
   - Expected: smooth 3-second pan to full right (StackChan's right hand side)
3. `bundle exec exe/stackchan-ble-control servo --yaw 1280 --pitch 450 --time 3000`
   - Expected: smooth 3-second pan to full left
4. `bundle exec exe/stackchan-ble-control servo --yaw 0 --pitch 30 --time 1500`
   - Expected: tilt down smoothly
5. `bundle exec exe/stackchan-ble-control servo --yaw 0 --pitch 870 --time 1500`
   - Expected: tilt up smoothly
6. `bundle exec exe/stackchan-ble-control servo --yaw 0 --pitch 450 --time 1000`
   - Expected: return to centered pose

### Observation criteria

- [ ] All movements complete without audible buzzing or grinding
- [ ] No servo overheats to the touch by end of run (chassis warm but not hot)
- [ ] Target positions are visually reached (±~5° tolerance by eye)
- [ ] No frame is silently dropped (each command produces visible motion)
- [ ] face / LED from Phase A still respond after the run (`stackchan-ble-control face smile` works post-servo)

## HITL log

| Date | Tester | Firmware commit | Result | Notes |
|---|---|---|---|---|
| YYYY-MM-DD | name | git short-sha | PASS / FAIL | observations |

### 2026-MM-DD initial pass

Run the procedure above and append a row to the log with results.
```

- [ ] **Step 2: Commit**

```bash
git add docs/superpowers/handoff/phase-b-hitl-checklist.md
git commit -m "docs(handoff): add Phase B servo HITL checklist"
```

- [ ] **Step 3: Wait for human HITL pass and log result**

This step is a human handoff — the tester runs the procedure, observes, and appends a row to the HITL log table. The agent cannot execute this autonomously; flag for user.

After the user reports the result, append the row in a follow-up commit:

```bash
git add docs/superpowers/handoff/phase-b-hitl-checklist.md
git commit -m "docs(handoff): record Phase B HITL initial pass result"
```

---

## Task 16: Final code review (per Phase A discipline)

**Files:** none (review only)

Per memory `feedback_final_review_catches_what_per_task_misses`, run a final code-reviewer pass over the complete Phase B diff before declaring done.

- [ ] **Step 1: Dispatch feature-dev:code-reviewer subagent**

Invoke `feature-dev:code-reviewer` with this prompt:

```
Review the Phase B servo implementation (commits since the spec doc 1d94a83). Scope:

- New mrbgem picoruby-scservo (Task 1-5): packet assembly correctness, signedness handling, drain logic, timeout behavior
- StackchanApp::Head (Task 6): clamp + T-priority/V-fallback policy
- Dispatcher Y/P/V/T branch (Task 7): ACK byte preservation + detail frame emission, error frame axis logic
- application.rb cold-boot servo init + StackChanApp wiring (Task 8): rescue/degradation path
- Build config + firmware build (Task 9-10): gem inclusion, no regression to Phase A boot
- Mac side SendBuilder/FrameCodec/CLI (Task 11-12): encoding consistency with device side
- Notifier hook (Task 13): pattern consistency with existing :notify dispatch
- Servo-verify skill + bin (Task 14): correctness of 5-target tolerance check
- HITL checklist (Task 15)

Filter to high-confidence issues only. Focus on:
1. Bytes-level protocol bugs (checksum, sign-magnitude, packet length)
2. Cross-layer naming consistency (Y/P/V/T keys appearing identically in gem / Head / Dispatcher / FrameCodec / CLI)
3. Operational risks (cold-boot failure paths, BLE detail frame interleaving with face/LED frames)
4. Test coverage gaps (any path with a `nil` return or rescue branch that isn't covered)

Skip style nits and minor doc rephrasing. Return findings as a list with severity (CRITICAL / HIGH / MEDIUM) and file:line references.
```

- [ ] **Step 2: Triage findings**

For each CRITICAL / HIGH finding, decide:
- **Fix now**: create a hotfix commit on top of Phase B with `fix(scservo|head|dispatcher|...): <issue>`
- **Defer with rationale**: document in a follow-up handoff doc, link the reviewer finding

For MEDIUM, batch into a single follow-up commit or defer based on impact.

- [ ] **Step 3: Re-run full host test suite + servo-verify**

```bash
bundle exec rake test
bundle exec exe/servo-verify
```

Delegate `rake test` to haiku subagent. Expected: 52 PASS, 0 omit + `RESULT: 5/5 PASS`. If hotfix commits were added, count may grow.

- [ ] **Step 4: Final commit (if hotfixes applied)**

```bash
git add <fixed files>
git commit -m "fix(phase-b): <issue summary> from code review"
```

- [ ] **Step 5: Mark Phase B complete**

Add to memory (via Write tool, not chat) a new memory file at `~/.claude/projects/-Users-bash-dev-src-github-com-bash0C7-stackchan-picoruby/memory/project_phase_b_servo_complete.md`:

```markdown
---
name: project-phase-b-servo-complete
description: Phase B (servo Y/P/V/T) implementation complete with picoruby-scservo gem + Head class + auto-verify + HITL passed
metadata:
  type: project
---

Phase B servo complete (date YYYY-MM-DD). Two-layer split: picoruby-scservo (generic SCSCL UART driver) + StackchanApp::Head (StackChan-specific axis mapping, range clamp, T-priority policy). 5 task scopes (picoruby-scservo / Head / Dispatcher branch / cold-boot + wiring / Mac CLI + notifier) plus auto-verify skill and HITL.

Test count: 52 PASS, 0 omit. Servo-verify: 5/5 PASS. HITL: PASS (date Y-M-D).

Out of scope (Phase C+): gesture macros, self-initiated BLE notify (HEARTBEAT/ALERT/EVENT), head-touch reactive movement.

Supersedes [[project-kawaii-ai-phase-a-code-complete]] as the current phase head.
```

Add an entry to `MEMORY.md`:

```
- [Phase B servo complete](project_phase_b_servo_complete.md) — picoruby-scservo + Head + auto-verify + HITL passed
```

---

## Done criteria

Phase B is complete when **all** of the following hold:

- `bundle exec rake test` reports 52+ PASS, 0 omit (host tests)
- `bundle exec exe/servo-verify` reports `RESULT: 5/5 PASS` against live hardware
- HITL checklist has at least one PASS row appended
- `feature-dev:code-reviewer` final pass returns no unresolved CRITICAL / HIGH findings
- The Phase B memory entry is added (Task 16 Step 5)
- All commits land on `main` and `git status` is clean (modulo untracked log dirs already excluded)
