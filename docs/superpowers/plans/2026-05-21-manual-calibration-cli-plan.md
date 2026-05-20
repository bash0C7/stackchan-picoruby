# Manual Calibration CLI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a BLE-driven `calibrate` CLI subcommand to `stackchan-ble-control` that supports (1) daily-startup align-only flow (`<torque:off>` → operator manually aligns → `<torque:on>`) and (2) 5-pose anchor recalibration that prints paste-ready SERVO_*_ZERO + RANGE_RAW constants for `application.rb`.

**Architecture:**
- Device side: one new dispatcher branch `<read:pos>` → emits detail `<yaw_raw:N,pitch_raw:M>` (or `unknown`).
- ble-client side: `FrameCodec.encode_read_pos`, `SendBuilder#read_pos`, and an extension to `Client#servo_frame?` so detail-frame draining handles the new frame too.
- CLI side: new `calibrate` subcommand with `--align-only`, `--samples N`, `--format`, `--engage-torque`, `--no-torque-toggle` flags; orchestrates the 5-pose workflow, computes anchors, prints formatted output, maps results to exit codes.

**Tech Stack:** PicoRuby (device), Ruby 4.x via Bundler / test-unit (host), `stackchan_ble_client` gem (PC), `rake test` (host suites), `/stackchan-device-iterate` skill (device deploy).

**Spec reference:** `docs/superpowers/specs/2026-05-21-manual-calibration-cli-design.md` (commit `51cc4a8`)

**Branch:** `feat/servo-tuning-and-test-fix` (continues current branch — same PR as Phase 1-7 + Task 15 close-out)

---

## File Map (what gets touched)

| File | Action | Why |
|---|---|---|
| `mrbgems/picoruby-stackchan-protocol/examples/application.rb` | modify (Dispatcher#handle, add `handle_read_pos`) | new BLE branch |
| `mrbgems/picoruby-stackchan-protocol/test/test_dispatcher_frame_contract.rb` | modify (append tests) | host coverage for new handler |
| `pc/stackchan-ble-client/lib/stackchan_ble_client/frame_codec.rb` | modify (add `encode_read_pos`) | new encoder |
| `pc/stackchan-ble-client/lib/stackchan_ble_client/send_builder.rb` | modify (add `#read_pos`, route in `encode`) | builder API |
| `pc/stackchan-ble-client/lib/stackchan_ble_client/client.rb` | modify (extend `servo_frame?` to also match `<read:` frames) | detail drain |
| `pc/stackchan-ble-client/test/frame_codec_test.rb` | modify (append tests) | encoder coverage |
| `pc/stackchan-ble-client/test/send_builder_test.rb` | modify (append tests) | builder coverage |
| `pc/stackchan-ble-client/test/client_test.rb` | modify (extend ServoDetailDrain tests) | detail-frame drain coverage |
| `pc/stackchan-ble-client/lib/stackchan_ble_client/calibration.rb` | **create** | calibration domain logic (sampling, anchor calc, formatters) — keeps `exe/stackchan-ble-control` thin |
| `pc/stackchan-ble-client/test/calibration_test.rb` | **create** | unit tests for sampling / anchor calc / formatters / abort branches |
| `pc/stackchan-ble-client/lib/stackchan_ble_client.rb` | modify (require_relative new file) | gem entry |
| `pc/stackchan-ble-client/exe/stackchan-ble-control` | modify (add `calibrate` case + flag parsers + EXIT_CALIBRATION_INCOMPLETE constant) | CLI wiring |
| `Rakefile` | modify (add `r2p2:ble_calibration_smoke` task) | HITL convenience |
| `CLAUDE.md` | modify (add `<read:pos>` line + `calibrate` subcommand note) | documented protocol |
| `docs/superpowers/specs/2026-05-21-cold-boot-torque-off-and-normalized-protocol-design.md` | modify (add `<read:pos>` row + cross-ref to new spec) | spec lineage |

Domain split rationale: `calibration.rb` keeps interactive I/O (prompts, sample loops) + pure-math (median / anchor / verify) + formatters in one focused module. `exe/stackchan-ble-control` becomes a thin parser + dispatch shim. Tests target `calibration.rb` directly without driving the executable.

---

## Phase 1 — Device-side `<read:pos>` handler

### Task 1: Failing host test for `<read:pos>` success path

**Files:**
- Modify: `mrbgems/picoruby-stackchan-protocol/test/test_dispatcher_frame_contract.rb` (append at end of `TestDispatcherFrameContract` class)

- [ ] **Step 1: Add failing test**

Append before the final `end` of `class TestDispatcherFrameContract`:

```ruby
  def test_read_pos_acks_then_emits_yaw_raw_pitch_raw_detail
    @head.instance_variable_set(:@yaw_pos, 485)
    @head.instance_variable_set(:@pitch_pos, 628)
    @dispatcher.handle({ "read" => "pos" })
    assert_equal 2, @stdout.frames.length
    assert_equal ".\n", @stdout.frames[0]
    assert_equal "<yaw_raw:485,pitch_raw:628>\n", @stdout.frames[1]
  end
```

- [ ] **Step 2: Run, verify it fails**

Run: `cd /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/mrbgems/picoruby-stackchan-protocol && bundle exec rake test TEST=test/test_dispatcher_frame_contract.rb`
Expected: FAIL — output frames length is 1 (existing dispatcher routes `read` key through the unknown-keys branch and emits a single ACK or ERROR, not the expected 2-frame detail sequence).

- [ ] **Step 3: Stop and proceed to Task 2 (do not implement here)**

### Task 2: Implement `handle_read_pos` in Dispatcher (green)

**Files:**
- Modify: `mrbgems/picoruby-stackchan-protocol/examples/application.rb:305-331` (Dispatcher#handle) and append new `handle_read_pos` after `handle_selftest`

- [ ] **Step 1: Add dispatch branch**

Edit `Dispatcher#handle` to insert one line **between** the existing `handle_torque` and `handle_selftest` branches (lines 313-314):

```ruby
      return handle_torque(frame)    if frame.key?("torque")
      return handle_selftest(frame)  if frame.key?("selftest")
      return handle_read_pos(frame)  if frame.key?("read")
```

- [ ] **Step 2: Add `handle_read_pos` private method**

Insert after `handle_selftest` (around line 372 in application.rb, between `handle_selftest` and `handle_led`):

```ruby
    def handle_read_pos(frame)
      unless frame["read"] == "pos"
        @stdout.write(ERROR_FRAME)
        return
      end
      if @head.nil?
        @stdout.write(ERROR_FRAME)
        return
      end
      @stdout.write(ACK_FRAME)
      actual = @head.read_actual
      yaw_raw   = actual[:yaw]
      pitch_raw = actual[:pitch]
      yaw_part   = yaw_raw.nil?   ? "yaw_raw:unknown"   : "yaw_raw:#{yaw_raw}"
      pitch_part = pitch_raw.nil? ? "pitch_raw:unknown" : "pitch_raw:#{pitch_raw}"
      @stdout.write("<#{yaw_part},#{pitch_part}>\n")
    end
```

- [ ] **Step 3: Run test, verify it passes**

Run: `cd mrbgems/picoruby-stackchan-protocol && bundle exec rake test TEST=test/test_dispatcher_frame_contract.rb`
Expected: PASS (existing tests still PASS, new test PASS).

### Task 3: Edge case tests + implementations

**Files:**
- Modify: `mrbgems/picoruby-stackchan-protocol/test/test_dispatcher_frame_contract.rb`

- [ ] **Step 1: Add failing edge-case tests**

Append:

```ruby
  def test_read_pos_with_invalid_value_emits_error
    @dispatcher.handle({ "read" => "bogus" })
    assert_equal ["?\n"], @stdout.frames
  end

  def test_read_pos_emits_unknown_when_head_read_actual_returns_nil_parts
    @head.fail_read = true
    @dispatcher.handle({ "read" => "pos" })
    assert_equal 2, @stdout.frames.length
    assert_equal ".\n", @stdout.frames[0]
    assert_equal "<yaw_raw:unknown,pitch_raw:unknown>\n", @stdout.frames[1]
  end

  def test_read_pos_emits_error_when_head_is_nil
    dispatcher = StackchanApp::Dispatcher.new(
      display: @display, led: @led, stdout: @stdout, head: nil
    )
    dispatcher.handle({ "read" => "pos" })
    assert_equal ["?\n"], @stdout.frames
  end
```

- [ ] **Step 2: Run, verify all PASS (no impl changes needed; Task 2 handler already covers these paths)**

Run: `cd mrbgems/picoruby-stackchan-protocol && bundle exec rake test TEST=test/test_dispatcher_frame_contract.rb`
Expected: all dispatcher_frame_contract tests PASS.

### Task 4: Phase 1 commit

- [ ] **Step 1: Stage and commit**

Run via general-purpose subagent (per `~/dev/src/CLAUDE.md` git-via-subagent rule):

```
git add mrbgems/picoruby-stackchan-protocol/examples/application.rb \
        mrbgems/picoruby-stackchan-protocol/test/test_dispatcher_frame_contract.rb
git commit -m "$(cat <<'EOF'
feat(dispatcher): add <read:pos> handler emitting raw yaw/pitch detail

New BLE frame <read:pos> for calibration workflow (spec
2026-05-21-manual-calibration-cli-design.md §Section 2). Acks then
emits <yaw_raw:N,pitch_raw:M> detail, or unknown parts when
Head#read_actual returns nil. Invalid value / head=nil → ERROR ACK.

Host contract tests cover all four paths.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 2 — ble-client gem extension

### Task 5: FrameCodec.encode_read_pos + tests

**Files:**
- Modify: `pc/stackchan-ble-client/lib/stackchan_ble_client/frame_codec.rb` (append after `encode_selftest`)
- Modify: `pc/stackchan-ble-client/test/frame_codec_test.rb` (append)

- [ ] **Step 1: Add failing test**

In `frame_codec_test.rb`, append:

```ruby
  def test_encode_read_pos
    assert_equal "<read:pos>\n", StackchanBleClient::FrameCodec.encode_read_pos
  end
```

- [ ] **Step 2: Run, verify it fails (`NoMethodError`)**

Run: `cd pc/stackchan-ble-client && bundle exec rake test TEST=test/frame_codec_test.rb`
Expected: FAIL — `NoMethodError: undefined method 'encode_read_pos'`.

- [ ] **Step 3: Implement encoder**

In `frame_codec.rb`, after `encode_selftest`:

```ruby
    def encode_read_pos
      encode_pairs("read" => "pos")
    end
```

- [ ] **Step 4: Run, verify PASS**

Run: `cd pc/stackchan-ble-client && bundle exec rake test TEST=test/frame_codec_test.rb`
Expected: PASS (all frame_codec tests).

### Task 6: SendBuilder#read_pos + tests

**Files:**
- Modify: `pc/stackchan-ble-client/lib/stackchan_ble_client/send_builder.rb`
- Modify: `pc/stackchan-ble-client/test/send_builder_test.rb`

- [ ] **Step 1: Add failing test**

In `send_builder_test.rb`, append after `test_selftest`:

```ruby
  def test_read_pos
    builder = StackchanBleClient::SendBuilder.new
    builder.read_pos
    assert_equal ["<read:pos>\n"], builder.to_frames
  end
```

- [ ] **Step 2: Run, verify it fails (`NoMethodError`)**

Run: `cd pc/stackchan-ble-client && bundle exec rake test TEST=test/send_builder_test.rb`
Expected: FAIL — `NoMethodError: undefined method 'read_pos'`.

- [ ] **Step 3: Implement builder method**

In `send_builder.rb`, add after `selftest` (~line 33):

```ruby
    def read_pos
      record(:read_pos, { kind: :read_pos })
    end
```

And add a `when` branch in `encode` (after `when :selftest`):

```ruby
      when :read_pos
        FrameCodec.encode_read_pos
```

- [ ] **Step 4: Run, verify PASS**

Run: `cd pc/stackchan-ble-client && bundle exec rake test TEST=test/send_builder_test.rb`
Expected: PASS.

### Task 7: Client detail-drain extension

**Files:**
- Modify: `pc/stackchan-ble-client/lib/stackchan_ble_client/client.rb:97-101`
- Modify: `pc/stackchan-ble-client/test/client_test.rb` (extend `ClientServoDetailDrainTest`)

- [ ] **Step 1: Add failing tests for read_pos detail drain**

In `client_test.rb`, append to `ClientServoDetailDrainTest`:

```ruby
  def test_read_pos_frame_drains_trailing_detail_frame_from_subscription
    transport = FakeTransport.new(
      acks: [".", "<yaw_raw:485,pitch_raw:628>\n"],
    )
    client = StackchanBleClient::Client.new(device_name: "X", transport: transport)
    client.connect
    client.send { |s| s.read_pos }
    assert_equal "<yaw_raw:485,pitch_raw:628>\n", client.last_detail_frame
  end

  def test_read_pos_unknown_detail_frame_still_drained
    transport = FakeTransport.new(
      acks: [".", "<yaw_raw:unknown,pitch_raw:unknown>\n"],
    )
    client = StackchanBleClient::Client.new(device_name: "X", transport: transport)
    client.connect
    client.send { |s| s.read_pos }
    assert_equal "<yaw_raw:unknown,pitch_raw:unknown>\n", client.last_detail_frame
  end
```

Note: `FakeTransport` is defined earlier in the same file. Reuse the existing one — do not create a new fake.

- [ ] **Step 2: Run, verify failure**

Run: `cd pc/stackchan-ble-client && bundle exec rake test TEST=test/client_test.rb`
Expected: FAIL — `last_detail_frame` is `nil` because `servo_frame?(frame)` for `<read:pos>\n` returns false (no `[YPVT]:` match), so the client never reads the second value.

- [ ] **Step 3: Extend `servo_frame?` (rename intent in comment, not method)**

Replace `client.rb:97-101`:

```ruby
    def servo_frame?(frame)
      # Device emits a detail frame after:
      # - any frame containing Y/P/V/T axis keys (servo command);
      # - any <read:pos> frame (calibration raw read).
      # Mirror the device-side dispatcher's "emits detail" set.
      !!(frame =~ /[YPVT]:/) || frame.start_with?("<read:")
    end
```

- [ ] **Step 4: Run, verify PASS**

Run: `cd pc/stackchan-ble-client && bundle exec rake test TEST=test/client_test.rb`
Expected: PASS (all client tests).

### Task 8: Phase 2 commit

- [ ] **Step 1: Commit via subagent**

```
git add pc/stackchan-ble-client/lib/stackchan_ble_client/frame_codec.rb \
        pc/stackchan-ble-client/lib/stackchan_ble_client/send_builder.rb \
        pc/stackchan-ble-client/lib/stackchan_ble_client/client.rb \
        pc/stackchan-ble-client/test/frame_codec_test.rb \
        pc/stackchan-ble-client/test/send_builder_test.rb \
        pc/stackchan-ble-client/test/client_test.rb
git commit -m "$(cat <<'EOF'
feat(ble-client): SendBuilder#read_pos + detail-frame drain for <read:pos>

Adds the PC-side counterpart to the new <read:pos> BLE frame
(spec 2026-05-21-manual-calibration-cli-design.md §Section 5). FrameCodec
encoder + SendBuilder method + Client servo_frame? extension so the
trailing <yaw_raw:N,pitch_raw:M> detail is drained into
last_detail_frame.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 3 — Calibration domain module + CLI subcommand

### Task 9: Scaffold `calibration.rb` module + median helper

**Files:**
- Create: `pc/stackchan-ble-client/lib/stackchan_ble_client/calibration.rb`
- Create: `pc/stackchan-ble-client/test/calibration_test.rb`
- Modify: `pc/stackchan-ble-client/lib/stackchan_ble_client.rb` (add `require_relative "stackchan_ble_client/calibration"`)

- [ ] **Step 1: Add failing test for median helper**

Create `pc/stackchan-ble-client/test/calibration_test.rb`:

```ruby
require "test_helper"

class CalibrationMedianTest < Test::Unit::TestCase
  def test_median_of_odd_count
    assert_equal 485, StackchanBleClient::Calibration.median([482, 485, 487])
  end

  def test_median_of_even_count_uses_lower_middle
    assert_equal 484, StackchanBleClient::Calibration.median([482, 484, 486, 488])
  end

  def test_median_single_value
    assert_equal 500, StackchanBleClient::Calibration.median([500])
  end

  def test_median_empty_raises
    assert_raise(ArgumentError) { StackchanBleClient::Calibration.median([]) }
  end
end
```

- [ ] **Step 2: Run, verify failure (`uninitialized constant`)**

Run: `cd pc/stackchan-ble-client && bundle exec rake test TEST=test/calibration_test.rb`
Expected: FAIL with `NameError: uninitialized constant StackchanBleClient::Calibration`.

- [ ] **Step 3: Create scaffold + median**

Create `pc/stackchan-ble-client/lib/stackchan_ble_client/calibration.rb`:

```ruby
module StackchanBleClient
  module Calibration
    module_function

    def median(values)
      raise ArgumentError, "median requires at least 1 value" if values.empty?
      sorted = values.sort
      sorted[(sorted.length - 1) / 2]
    end
  end
end
```

Add to `pc/stackchan-ble-client/lib/stackchan_ble_client.rb` (just before the closing module if it has one, or beside other `require_relative`):

```ruby
require_relative "stackchan_ble_client/calibration"
```

- [ ] **Step 4: Run, verify PASS**

Run: `cd pc/stackchan-ble-client && bundle exec rake test TEST=test/calibration_test.rb`
Expected: PASS.

### Task 10: Anchor calculation pure function

**Files:**
- Modify: `pc/stackchan-ble-client/lib/stackchan_ble_client/calibration.rb`
- Modify: `pc/stackchan-ble-client/test/calibration_test.rb`

- [ ] **Step 1: Add failing tests**

Append to `calibration_test.rb`:

```ruby
class CalibrationComputeAnchorsTest < Test::Unit::TestCase
  def sample_pose(yaw, pitch)
    { yaw_raw: yaw, pitch_raw: pitch }
  end

  def test_symmetric_ranges
    result = StackchanBleClient::Calibration.compute_anchors(
      forward:    sample_pose(485, 628),
      left_max:   sample_pose(530, 628),
      right_max:  sample_pose(440, 628),
      up_max:     sample_pose(485, 660),
      fwd_verify: sample_pose(485, 628),
    )
    assert_equal 485, result[:servo_yaw_zero]
    assert_equal 628, result[:servo_pitch_zero]
    assert_equal 45,  result[:yaw_range_raw]
    assert_equal 32,  result[:pitch_range_raw]
    assert_equal({ yaw_delta: 0, pitch_delta: 0 }, result[:forward_verify])
  end

  def test_asymmetric_yaw_picks_min_radius
    result = StackchanBleClient::Calibration.compute_anchors(
      forward:    sample_pose(485, 628),
      left_max:   sample_pose(540, 628),   # +55
      right_max:  sample_pose(450, 628),   # -35
      up_max:     sample_pose(485, 660),
      fwd_verify: sample_pose(485, 628),
    )
    assert_equal 35, result[:yaw_range_raw]
  end

  def test_forward_verify_records_delta_signed
    result = StackchanBleClient::Calibration.compute_anchors(
      forward:    sample_pose(485, 628),
      left_max:   sample_pose(530, 628),
      right_max:  sample_pose(440, 628),
      up_max:     sample_pose(485, 660),
      fwd_verify: sample_pose(488, 626),
    )
    assert_equal({ yaw_delta: 3, pitch_delta: -2 }, result[:forward_verify])
  end
end
```

- [ ] **Step 2: Run, verify failure**

Run: `cd pc/stackchan-ble-client && bundle exec rake test TEST=test/calibration_test.rb`
Expected: FAIL — `NoMethodError: undefined method 'compute_anchors'`.

- [ ] **Step 3: Implement**

Append to `calibration.rb` inside `module Calibration`:

```ruby
    def compute_anchors(forward:, left_max:, right_max:, up_max:, fwd_verify:)
      yaw_zero   = forward[:yaw_raw]
      pitch_zero = forward[:pitch_raw]
      left_radius  = (left_max[:yaw_raw]  - yaw_zero).abs
      right_radius = (right_max[:yaw_raw] - yaw_zero).abs
      {
        servo_yaw_zero:   yaw_zero,
        servo_pitch_zero: pitch_zero,
        yaw_range_raw:    [left_radius, right_radius].min,
        pitch_range_raw:  (up_max[:pitch_raw] - pitch_zero).abs,
        forward_verify: {
          yaw_delta:   fwd_verify[:yaw_raw]   - yaw_zero,
          pitch_delta: fwd_verify[:pitch_raw] - pitch_zero,
        },
      }
    end
```

- [ ] **Step 4: Run, verify PASS**

Run: `cd pc/stackchan-ble-client && bundle exec rake test TEST=test/calibration_test.rb`
Expected: PASS.

### Task 11: Verify-tolerance classification

**Files:**
- Modify: `pc/stackchan-ble-client/lib/stackchan_ble_client/calibration.rb`
- Modify: `pc/stackchan-ble-client/test/calibration_test.rb`

- [ ] **Step 1: Add failing tests**

Append:

```ruby
class CalibrationClassifyVerifyTest < Test::Unit::TestCase
  def test_pass_within_three
    result = StackchanBleClient::Calibration.classify_verify(yaw_delta: 2, pitch_delta: -3)
    assert_equal :pass, result
  end

  def test_warn_above_three_within_ten
    result = StackchanBleClient::Calibration.classify_verify(yaw_delta: 5, pitch_delta: 0)
    assert_equal :warn, result
  end

  def test_warn_when_only_pitch_exceeds
    result = StackchanBleClient::Calibration.classify_verify(yaw_delta: 1, pitch_delta: -8)
    assert_equal :warn, result
  end

  def test_fail_above_ten
    result = StackchanBleClient::Calibration.classify_verify(yaw_delta: 12, pitch_delta: 0)
    assert_equal :fail, result
  end
end
```

- [ ] **Step 2: Run, verify failure**

Run: `cd pc/stackchan-ble-client && bundle exec rake test TEST=test/calibration_test.rb`
Expected: FAIL — `NoMethodError: classify_verify`.

- [ ] **Step 3: Implement**

```ruby
    PASS_TOLERANCE = 3
    FAIL_TOLERANCE = 10

    def classify_verify(yaw_delta:, pitch_delta:)
      worst = [yaw_delta.abs, pitch_delta.abs].max
      return :fail if worst > FAIL_TOLERANCE
      return :warn if worst > PASS_TOLERANCE
      :pass
    end
```

- [ ] **Step 4: Run, verify PASS**

Run: `cd pc/stackchan-ble-client && bundle exec rake test TEST=test/calibration_test.rb`

### Task 12: Output formatters (ruby / json / env)

**Files:**
- Modify: `pc/stackchan-ble-client/lib/stackchan_ble_client/calibration.rb`
- Modify: `pc/stackchan-ble-client/test/calibration_test.rb`

- [ ] **Step 1: Add failing tests**

Append:

```ruby
class CalibrationFormatTest < Test::Unit::TestCase
  def anchors
    {
      servo_yaw_zero: 485, servo_pitch_zero: 628,
      yaw_range_raw: 45, pitch_range_raw: 32,
      forward_verify: { yaw_delta: 1, pitch_delta: 0 },
    }
  end

  def test_format_ruby
    out = StackchanBleClient::Calibration.format(anchors, :ruby)
    assert_match(/^SERVO_YAW_ZERO\s*=\s*485$/,   out)
    assert_match(/^SERVO_PITCH_ZERO\s*=\s*628$/, out)
    assert_match(/^YAW_RANGE_RAW\s*=\s*45$/,     out)
    assert_match(/^PITCH_RANGE_RAW\s*=\s*32$/,   out)
  end

  def test_format_env
    out = StackchanBleClient::Calibration.format(anchors, :env)
    assert_equal(
      "SERVO_YAW_ZERO=485\nSERVO_PITCH_ZERO=628\nYAW_RANGE_RAW=45\nPITCH_RANGE_RAW=32\n",
      out
    )
  end

  def test_format_json
    out = StackchanBleClient::Calibration.format(anchors, :json)
    parsed = JSON.parse(out)
    assert_equal 485, parsed["servo_yaw_zero"]
    assert_equal 32,  parsed["pitch_range_raw"]
    assert_equal 1,   parsed["forward_verify"]["yaw_delta"]
  end

  def test_format_unknown_raises
    assert_raise(ArgumentError) { StackchanBleClient::Calibration.format(anchors, :yaml) }
  end
end
```

- [ ] **Step 2: Run, verify failure**

Run: `cd pc/stackchan-ble-client && bundle exec rake test TEST=test/calibration_test.rb`
Expected: FAIL — `NoMethodError: format`.

- [ ] **Step 3: Implement formatters**

In `calibration.rb`, add `require "json"` at the top, then:

```ruby
    def format(anchors, fmt)
      case fmt
      when :ruby then format_ruby(anchors)
      when :env  then format_env(anchors)
      when :json then format_json(anchors)
      else
        raise ArgumentError, "unknown format: #{fmt.inspect} (must be :ruby / :env / :json)"
      end
    end

    def format_ruby(a)
      <<~RUBY
        SERVO_YAW_ZERO   = #{a[:servo_yaw_zero]}
        SERVO_PITCH_ZERO = #{a[:servo_pitch_zero]}
        YAW_RANGE_RAW    = #{a[:yaw_range_raw]}
        PITCH_RANGE_RAW  = #{a[:pitch_range_raw]}
      RUBY
    end

    def format_env(a)
      "SERVO_YAW_ZERO=#{a[:servo_yaw_zero]}\n" \
      "SERVO_PITCH_ZERO=#{a[:servo_pitch_zero]}\n" \
      "YAW_RANGE_RAW=#{a[:yaw_range_raw]}\n" \
      "PITCH_RANGE_RAW=#{a[:pitch_range_raw]}\n"
    end

    def format_json(a)
      JSON.generate({
        servo_yaw_zero:   a[:servo_yaw_zero],
        servo_pitch_zero: a[:servo_pitch_zero],
        yaw_range_raw:    a[:yaw_range_raw],
        pitch_range_raw:  a[:pitch_range_raw],
        forward_verify:   a[:forward_verify],
      })
    end
```

- [ ] **Step 4: Run, verify PASS**

Run: `cd pc/stackchan-ble-client && bundle exec rake test TEST=test/calibration_test.rb`

### Task 13: Detail-frame parser for `<yaw_raw:N,pitch_raw:M>`

**Files:**
- Modify: `pc/stackchan-ble-client/lib/stackchan_ble_client/calibration.rb`
- Modify: `pc/stackchan-ble-client/test/calibration_test.rb`

- [ ] **Step 1: Add failing tests**

Append:

```ruby
class CalibrationParseRawDetailTest < Test::Unit::TestCase
  def test_parse_numeric_pair
    pose = StackchanBleClient::Calibration.parse_raw_detail("<yaw_raw:485,pitch_raw:628>\n")
    assert_equal({ yaw_raw: 485, pitch_raw: 628 }, pose)
  end

  def test_parse_unknown_yaw
    pose = StackchanBleClient::Calibration.parse_raw_detail("<yaw_raw:unknown,pitch_raw:628>\n")
    assert_nil pose[:yaw_raw]
    assert_equal 628, pose[:pitch_raw]
  end

  def test_parse_both_unknown
    pose = StackchanBleClient::Calibration.parse_raw_detail("<yaw_raw:unknown,pitch_raw:unknown>\n")
    assert_nil pose[:yaw_raw]
    assert_nil pose[:pitch_raw]
  end

  def test_parse_negative_value
    pose = StackchanBleClient::Calibration.parse_raw_detail("<yaw_raw:-27139,pitch_raw:628>\n")
    assert_equal(-27139, pose[:yaw_raw])
  end

  def test_parse_malformed_raises
    assert_raise(ArgumentError) { StackchanBleClient::Calibration.parse_raw_detail(".\n") }
  end
end
```

- [ ] **Step 2: Run, verify failure (`NoMethodError`)**

- [ ] **Step 3: Implement**

```ruby
    def parse_raw_detail(frame)
      m = frame.match(/\A<yaw_raw:(unknown|-?\d+),pitch_raw:(unknown|-?\d+)>\n?\z/)
      raise ArgumentError, "not a raw detail frame: #{frame.inspect}" unless m
      {
        yaw_raw:   (m[1] == "unknown" ? nil : m[1].to_i),
        pitch_raw: (m[2] == "unknown" ? nil : m[2].to_i),
      }
    end
```

- [ ] **Step 4: Run, verify PASS**

### Task 14: Sample-with-retry helper (driver-facing)

**Files:**
- Modify: `pc/stackchan-ble-client/lib/stackchan_ble_client/calibration.rb`
- Modify: `pc/stackchan-ble-client/test/calibration_test.rb`

- [ ] **Step 1: Add failing tests**

Append:

```ruby
class CalibrationSampleTest < Test::Unit::TestCase
  class FakeClient
    attr_reader :detail_frames_left, :send_calls
    def initialize(detail_frames)
      @detail_frames_left = detail_frames.dup
      @send_calls = 0
    end
    def send(&block)
      @send_calls += 1
      block.call(self)
      self
    end
    def read_pos; end
    def last_detail_frame
      @detail_frames_left.shift
    end
  end

  def test_sample_pose_returns_median_of_n_reads
    client = FakeClient.new([
      "<yaw_raw:482,pitch_raw:627>\n",
      "<yaw_raw:485,pitch_raw:628>\n",
      "<yaw_raw:487,pitch_raw:629>\n",
    ])
    pose = StackchanBleClient::Calibration.sample_pose(client, samples: 3)
    assert_equal 485, pose[:yaw_raw]
    assert_equal 628, pose[:pitch_raw]
    assert_equal 3, client.send_calls
  end

  def test_sample_pose_raises_when_any_unknown
    client = FakeClient.new([
      "<yaw_raw:485,pitch_raw:628>\n",
      "<yaw_raw:unknown,pitch_raw:628>\n",
      "<yaw_raw:487,pitch_raw:628>\n",
    ])
    assert_raise(StackchanBleClient::Calibration::UnknownReadError) do
      StackchanBleClient::Calibration.sample_pose(client, samples: 3)
    end
  end

  def test_sample_pose_single_sample
    client = FakeClient.new(["<yaw_raw:500,pitch_raw:620>\n"])
    pose = StackchanBleClient::Calibration.sample_pose(client, samples: 1)
    assert_equal 500, pose[:yaw_raw]
  end
end
```

- [ ] **Step 2: Run, verify failure**

- [ ] **Step 3: Implement**

In `calibration.rb`, add the error class and `sample_pose` inside `module Calibration`:

```ruby
    class UnknownReadError < StandardError; end

    def sample_pose(client, samples:)
      readings = []
      samples.times do
        client.send { |s| s.read_pos }
        parsed = parse_raw_detail(client.last_detail_frame.to_s)
        raise UnknownReadError, "device returned unknown" if parsed[:yaw_raw].nil? || parsed[:pitch_raw].nil?
        readings << parsed
      end
      {
        yaw_raw:   median(readings.map { |r| r[:yaw_raw] }),
        pitch_raw: median(readings.map { |r| r[:pitch_raw] }),
      }
    end
```

- [ ] **Step 4: Run, verify PASS**

### Task 15: Workflow runner — `run_align_only` (system A)

**Files:**
- Modify: `pc/stackchan-ble-client/lib/stackchan_ble_client/calibration.rb`
- Modify: `pc/stackchan-ble-client/test/calibration_test.rb`

- [ ] **Step 1: Add failing test**

Append:

```ruby
class CalibrationAlignOnlyTest < Test::Unit::TestCase
  class ScriptedClient
    attr_reader :sent
    def initialize; @sent = []; end
    def send(&block)
      collector = Collector.new(@sent)
      block.call(collector)
      self
    end
    class Collector
      def initialize(sink); @sink = sink; end
      def torque(on:); @sink << [:torque, on]; end
      def read_pos;    @sink << [:read_pos]; end
    end
  end

  def test_run_align_only_sends_torque_off_prompts_then_torque_on
    client = ScriptedClient.new
    prompts = []
    StackchanBleClient::Calibration.run_align_only(
      client: client,
      prompt: ->(msg) { prompts << msg },
      stdout: StringIO.new,
    )
    assert_equal [[:torque, false], [:torque, true]], client.sent
    assert_equal 1, prompts.length
    assert_match(/FORWARD/, prompts[0])
  end
end
```

- [ ] **Step 2: Run, verify failure**

- [ ] **Step 3: Implement**

```ruby
    def run_align_only(client:, prompt:, stdout:)
      stdout.puts "[1/3] sending <torque:off>..."
      client.send { |s| s.torque(on: false) }
      stdout.puts "       ACK ✓ (Face::Closed displayed)"
      prompt.call("[2/3] Align head to FORWARD (yaw center, pitch center). Press Enter when aligned (Ctrl-C to abort)...")
      stdout.puts "[3/3] sending <torque:on>..."
      client.send { |s| s.torque(on: true) }
      stdout.puts "       ACK ✓ (Face::Neutral displayed)"
      stdout.puts "[done] Ready for operation."
    end
```

- [ ] **Step 4: Run, verify PASS**

### Task 16: Workflow runner — `run_full_calibrate` (system B)

**Files:**
- Modify: `pc/stackchan-ble-client/lib/stackchan_ble_client/calibration.rb`
- Modify: `pc/stackchan-ble-client/test/calibration_test.rb`

- [ ] **Step 1: Add failing tests for happy path + Ctrl-C abort + verify-fail**

Append:

```ruby
class CalibrationFullRunTest < Test::Unit::TestCase
  class ScriptedFullClient
    attr_reader :sent, :detail_frames_left
    def initialize(detail_frames)
      @sent = []
      @detail_frames_left = detail_frames.dup
    end
    def send(&block)
      collector = Collector.new(@sent)
      block.call(collector)
      self
    end
    def last_detail_frame; @detail_frames_left.shift; end
    class Collector
      def initialize(sink); @sink = sink; end
      def torque(on:); @sink << [:torque, on]; end
      def read_pos;    @sink << [:read_pos]; end
    end
  end

  def make_client_with_poses(forward:, left:, right:, up:, verify:)
    frames = [forward, left, right, up, verify].map { |p|
      "<yaw_raw:#{p[0]},pitch_raw:#{p[1]}>\n"
    }
    ScriptedFullClient.new(frames)
  end

  def test_run_full_calibrate_happy_path_returns_anchors_outcome_pass
    client = make_client_with_poses(
      forward: [485, 628], left: [530, 628], right: [440, 628],
      up: [485, 660], verify: [486, 628],
    )
    result = StackchanBleClient::Calibration.run_full_calibrate(
      client: client,
      prompt: ->(_msg) { nil },
      stdout: StringIO.new,
      samples: 1,
      engage_torque: false,
    )
    assert_equal :pass, result[:outcome]
    assert_equal 485,   result[:anchors][:servo_yaw_zero]
    assert_equal 45,    result[:anchors][:yaw_range_raw]
    assert_equal 32,    result[:anchors][:pitch_range_raw]
    refute_includes client.sent, [:torque, true]
  end

  def test_run_full_calibrate_engage_torque_sends_torque_on_at_end
    client = make_client_with_poses(
      forward: [485, 628], left: [530, 628], right: [440, 628],
      up: [485, 660], verify: [485, 628],
    )
    StackchanBleClient::Calibration.run_full_calibrate(
      client: client,
      prompt: ->(_msg) { nil },
      stdout: StringIO.new,
      samples: 1,
      engage_torque: true,
    )
    assert_equal [:torque, true], client.sent.last
  end

  def test_run_full_calibrate_verify_fail_returns_outcome_fail
    client = make_client_with_poses(
      forward: [485, 628], left: [530, 628], right: [440, 628],
      up: [485, 660], verify: [500, 628],     # Δyaw=15 > 10 → fail
    )
    result = StackchanBleClient::Calibration.run_full_calibrate(
      client: client,
      prompt: ->(_msg) { nil },
      stdout: StringIO.new,
      samples: 1,
      engage_torque: false,
    )
    assert_equal :fail, result[:outcome]
  end

  def test_run_full_calibrate_propagates_unknown_read_error
    client = ScriptedFullClient.new([
      "<yaw_raw:unknown,pitch_raw:unknown>\n",
    ])
    assert_raise(StackchanBleClient::Calibration::UnknownReadError) do
      StackchanBleClient::Calibration.run_full_calibrate(
        client: client,
        prompt: ->(_msg) { nil },
        stdout: StringIO.new,
        samples: 1,
        engage_torque: false,
      )
    end
  end

  def test_run_full_calibrate_propagates_operator_abort
    abort_prompt = ->(_msg) { raise Interrupt }
    client = ScriptedFullClient.new([])
    assert_raise(Interrupt) do
      StackchanBleClient::Calibration.run_full_calibrate(
        client: client,
        prompt: abort_prompt,
        stdout: StringIO.new,
        samples: 1,
        engage_torque: false,
      )
    end
  end
end
```

- [ ] **Step 2: Run, verify failure**

- [ ] **Step 3: Implement**

```ruby
    POSE_PROMPTS = [
      [:forward,    "[2/6] Align head to FORWARD (yaw center, pitch center). Press Enter..."],
      [:left_max,   "[3/6] Rotate head to STACKCHAN-LEFT MAX (operator's right side). Press Enter..."],
      [:right_max,  "[4/6] Rotate head to STACKCHAN-RIGHT MAX (operator's left side). Press Enter..."],
      [:up_max,     "[5/6] Tilt head UP MAX. Press Enter..."],
      [:fwd_verify, "[6/6] Re-align to FORWARD for verification. Press Enter..."],
    ].freeze

    def run_full_calibrate(client:, prompt:, stdout:, samples:, engage_torque:)
      stdout.puts "[1/6] sending <torque:off>..."
      client.send { |s| s.torque(on: false) }
      stdout.puts "       ACK ✓"

      poses = {}
      POSE_PROMPTS.each do |key, msg|
        prompt.call(msg)
        poses[key] = sample_pose(client, samples: samples)
        stdout.puts "       reading... yaw_raw=#{poses[key][:yaw_raw]} pitch_raw=#{poses[key][:pitch_raw]}"
      end

      anchors = compute_anchors(
        forward:    poses[:forward],
        left_max:   poses[:left_max],
        right_max:  poses[:right_max],
        up_max:     poses[:up_max],
        fwd_verify: poses[:fwd_verify],
      )
      outcome = classify_verify(**anchors[:forward_verify])

      if engage_torque
        client.send { |s| s.torque(on: true) }
        stdout.puts "[engage] <torque:on> sent."
      end

      { outcome: outcome, anchors: anchors, poses: poses }
    end
```

- [ ] **Step 4: Run, verify all PASS**

Run: `cd pc/stackchan-ble-client && bundle exec rake test TEST=test/calibration_test.rb`

### Task 17: CLI wire-up — flags + dispatch

**Files:**
- Modify: `pc/stackchan-ble-client/exe/stackchan-ble-control:8-15` (constants) and add `when "calibrate"` case

- [ ] **Step 1: Add `EXIT_CALIBRATION_INCOMPLETE` constant**

In `exe/stackchan-ble-control`, replace lines 8-14 with:

```ruby
EXIT_OK                       = 0
EXIT_ADAPTER                  = 2
EXIT_TIMEOUT                  = 3
EXIT_CONNECTION               = 4
EXIT_ASSERTION                = 5
EXIT_CALIBRATION_NEEDED       = 6
EXIT_CALIBRATION_INCOMPLETE   = 7
EXIT_UNCAT                    = 9
```

- [ ] **Step 2: Add OptionParser flags**

After the existing `opts.on("--velocity V")` line (~line 38), add:

```ruby
  opts.on("--align-only")      { $cal_align_only      = true }
  opts.on("--engage-torque")   { $cal_engage_torque   = true }
  opts.on("--no-torque-toggle"){ $cal_no_torque_toggle = true }
  opts.on("--samples N")       { |v| $cal_samples     = Integer(v, 10) }
  opts.on("--format FORMAT")   { |v| $cal_format      = v.to_sym }
```

- [ ] **Step 3: Update error string + add `calibrate` case branch**

Replace line 43:

```ruby
abort "error: command required (face / led / led-rgb / led-hsb / combo / servo / torque / selftest / calibrate / raw)" unless command
```

Add a new `when` branch in the `case command` block (after `when "selftest"`):

```ruby
  when "calibrate"
    samples       = $cal_samples || 3
    format        = $cal_format  || :ruby
    align_only    = !!$cal_align_only
    engage_torque = !!$cal_engage_torque
    skip_torque   = !!$cal_no_torque_toggle
    prompt_proc = ->(msg) { STDOUT.print "#{msg} "; STDOUT.flush; STDIN.gets }
    begin
      if align_only
        unless skip_torque
          StackchanBleClient::Calibration.run_align_only(
            client: client, prompt: prompt_proc, stdout: STDOUT,
          )
        else
          prompt_proc.call("Align head to FORWARD. Press Enter when ready...")
        end
        exit EXIT_OK
      else
        result = StackchanBleClient::Calibration.run_full_calibrate(
          client: client, prompt: prompt_proc, stdout: STDOUT,
          samples: samples, engage_torque: engage_torque,
        )
        STDOUT.puts "\n#{StackchanBleClient::Calibration.format(result[:anchors], format)}"
        case result[:outcome]
        when :pass then exit EXIT_OK
        when :warn
          warn "[WARN] verify pose Δ exceeded #{StackchanBleClient::Calibration::PASS_TOLERANCE} (yaw=#{result[:anchors][:forward_verify][:yaw_delta]}, pitch=#{result[:anchors][:forward_verify][:pitch_delta]}). Constants printed anyway; review before paste."
          exit EXIT_OK
        when :fail
          warn "[FAIL] verify pose Δ exceeded #{StackchanBleClient::Calibration::FAIL_TOLERANCE}. Calibration incomplete."
          exit EXIT_CALIBRATION_INCOMPLETE
        end
      end
    rescue StackchanBleClient::Calibration::UnknownReadError => e
      warn "[FAIL] reason=#{e.message} domain=calibration (device returned unknown)"
      exit EXIT_CALIBRATION_NEEDED
    rescue Interrupt
      warn "[INTERRUPT] operator aborted calibration; torque remains off."
      exit EXIT_CALIBRATION_INCOMPLETE
    end
```

- [ ] **Step 4: Smoke check parser (no real BLE)**

Run: `cd pc/stackchan-ble-client && bundle exec exe/stackchan-ble-control --help 2>&1 | head -5 || true`
Expected: option-parse succeeds (it'll error after on missing command since `--help` isn't wired; that's fine — verifies the OptionParser DSL block has no syntax error).

For a no-network sanity check, run with `--device NONEXISTENT calibrate --align-only` and let it fail with `EXIT_CONNECTION=4`:

Run: `cd pc/stackchan-ble-client && bundle exec exe/stackchan-ble-control --device NONEXISTENT calibrate --align-only; echo "exit=$?"`
Expected: prints `[FAIL] ... domain=connection`, then `exit=4`.

### Task 18: Phase 3 commit

- [ ] **Step 1: Commit via subagent**

```
git add pc/stackchan-ble-client/lib/stackchan_ble_client/calibration.rb \
        pc/stackchan-ble-client/lib/stackchan_ble_client.rb \
        pc/stackchan-ble-client/test/calibration_test.rb \
        pc/stackchan-ble-client/exe/stackchan-ble-control
git commit -m "$(cat <<'EOF'
feat(ble-control): calibrate subcommand — align-only + 5-pose anchor

New PC-side calibration domain module (sampling / median / anchor calc /
verify classification / formatters) and `calibrate` CLI subcommand
covering both the daily startup --align-only flow and the full 5-pose
anchor recalibration (spec 2026-05-21-manual-calibration-cli-design.md
§Section 1, 3, 4). Adds EXIT_CALIBRATION_INCOMPLETE=7 for verify-fail /
operator abort, reuses EXIT_CALIBRATION_NEEDED=6 for device unknown.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 4 — Rakefile + docs + HITL

### Task 19: Rakefile smoke task

**Files:**
- Modify: `Rakefile` (append to `r2p2:` namespace section)

- [ ] **Step 1: Add task**

In `Rakefile`, locate the `namespace :r2p2 do` block and append before its `end`:

```ruby
    desc "smoke test the calibrate CLI in --align-only mode (interactive, requires connected device)"
    task :ble_calibration_smoke do
      ensure_no_concurrent_monitor
      sh "cd pc/stackchan-ble-client && bundle exec exe/stackchan-ble-control calibrate --align-only --name-prefix StackChan"
    end
```

- [ ] **Step 2: Verify task lists**

Run: `bundle exec rake -T r2p2:ble_calibration_smoke`
Expected: line `rake r2p2:ble_calibration_smoke  # smoke test the calibrate CLI ...`

### Task 20: Update CLAUDE.md

**Files:**
- Modify: `CLAUDE.md` — the "BLE servo control protocol" section

- [ ] **Step 1: Add new frame + subcommand documentation**

In the "BLE servo control protocol (post-2026-05-21)" section, after the `<selftest:run>` bullet, add:

```markdown
- **read_pos (rare)**: `<read:pos>` (full-word key) — returns `<yaw_raw:N,pitch_raw:M>` detail (or `unknown` parts). Used only by `stackchan-ble-control calibrate`; no other operational caller.
```

In the same section, after the existing `CLI:` line, append:

```markdown
Calibration: `bundle exec exe/stackchan-ble-control calibrate --align-only` (daily startup: torque off → operator aligns forward → torque on).
Anchor recal: `bundle exec exe/stackchan-ble-control calibrate [--samples N] [--format ruby|json|env]` (5-pose, prints SERVO_*_ZERO / RANGE_RAW constants for paste into application.rb). Exit code 6 = device read unknown, 7 = verify fail / abort. Spec: `docs/superpowers/specs/2026-05-21-manual-calibration-cli-design.md`.
```

### Task 21: Cross-reference in cold-boot spec

**Files:**
- Modify: `docs/superpowers/specs/2026-05-21-cold-boot-torque-off-and-normalized-protocol-design.md`

- [ ] **Step 1: Add `<read:pos>` to frame table (Section 2)**

In the Section 2 "Frame syntax 全 key" table, after the `selftest` row, add:

```markdown
| `read` | `pos` | 現在 raw servo position 読出 (calibration CLI 専用、後続 spec で詳述) | system |
```

- [ ] **Step 2: Add cross-reference in Out of scope section**

In the Out of scope section, change the line:

```
- **calibration の persistent storage** — 個体ごとの raw zero 補正値を flash に保存する話は別 spec
```

to:

```
- **calibration の persistent storage** — 個体ごとの raw zero 補正値を flash に保存する話は別 spec (operator manual cal CLI は `docs/superpowers/specs/2026-05-21-manual-calibration-cli-design.md`、persistent storage はそこでも out-of-scope)
```

### Task 22: Phase 4 commit

- [ ] **Step 1: Commit via subagent**

```
git add Rakefile CLAUDE.md \
        docs/superpowers/specs/2026-05-21-cold-boot-torque-off-and-normalized-protocol-design.md
git commit -m "$(cat <<'EOF'
docs+rake: wire calibrate CLI into Rakefile + CLAUDE.md + cold-boot spec

Adds r2p2:ble_calibration_smoke convenience task, documents the
<read:pos> frame and `calibrate` subcommand in CLAUDE.md, and
cross-references the new manual-cal-cli spec from the cold-boot spec.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 23: HITL — execute `calibrate` on real device

This task replaces Task 24 in the prior plan (HITL 5-position calibration).

**Prerequisites:**
- USB cable connected (per handoff-2026-05-21-task15-blocker §"Resume trigger")
- Device cold-booted via `/stackchan-device-iterate` or `/stackchan-device-reset`
- BLE name visible from Mac (`bundle exec exe/stackchan-ble-control --name-prefix StackChan calibrate --align-only` should reach device)

**Steps:**

- [ ] **Step 1: Run `--align-only` to verify daily flow**

```bash
cd pc/stackchan-ble-client
bundle exec exe/stackchan-ble-control --name-prefix StackChan calibrate --align-only
```

Operator action: when CLI prompts FORWARD, manually rotate head to forward and tilt up to neutral. Press Enter.

Expected: `exit=0`. Servo should hold position after torque-on; head should remain in forward orientation when released.

- [ ] **Step 2: Run full `calibrate` 5-pose**

```bash
bundle exec exe/stackchan-ble-control --name-prefix StackChan calibrate --samples 3
```

Operator: align to FORWARD → LEFT-MAX → RIGHT-MAX → UP-MAX → FORWARD-verify on each prompt (per spec §Section 1.B).

Expected: output ends with a `ruby`-format constants block, `exit=0` (or 7 if verify fail).

- [ ] **Step 3: Paste constants into application.rb**

Open `mrbgems/picoruby-stackchan-protocol/examples/application.rb`, find `class Head` (the section with `SERVO_YAW_ZERO = 460`), replace the four constants with the output values.

- [ ] **Step 4: Redeploy and verify**

Run via `/stackchan-device-iterate SRC=mrbgems/picoruby-stackchan-protocol/examples/application.rb`.

- [ ] **Step 5: Send physical sanity command**

```bash
bundle exec exe/stackchan-ble-control --name-prefix StackChan torque on
bundle exec exe/stackchan-ble-control --name-prefix StackChan --yaw-left 0 --pitch-up 0 --time 500 servo
```

Expected: head visibly returns to the forward position you physically aligned in Step 2.

```bash
bundle exec exe/stackchan-ble-control --name-prefix StackChan --yaw-left 100 --time 500 servo
```

Expected: head visibly rotates fully to StackChan's left (operator's right).

- [ ] **Step 6: Commit constants update**

```
git add mrbgems/picoruby-stackchan-protocol/examples/application.rb
git commit -m "$(cat <<'EOF'
chore(application): rebaseline SERVO_*_ZERO / RANGE_RAW from operator calibrate

Constants from `stackchan-ble-control calibrate` HITL run on the
physical CoreS3 unit. Replaces Phase B default anchors (460 / 620 / 50
/ 30) with per-unit calibrated values.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 24: Run full host test suites (verification-before-completion)

- [ ] **Step 1: Run all 4 test suites in parallel via subagent (haiku, foreground, 300s each)**

Dispatch a single general-purpose subagent with this prompt:

> Run these 4 commands sequentially in the foreground from `/Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby`. For each, capture pass/fail and test count only (do not return full logs). Use 300000ms timeout per command. Under 200 words total.
>
> 1. `bundle exec rake test`
> 2. `cd mrbgems/picoruby-stackchan-protocol && bundle exec rake test`
> 3. `cd pc/stackchan-ble-client && bundle exec rake test`
> 4. `cd pc/stackchan-notifier && bundle exec rake test`
>
> Report: suite name, test/assertion counts, failure count, any error names.

- [ ] **Step 2: Verify all 4 suites are 100% green (failure count 0)**

If any failure: fix in-place, re-run only the failed suite.

### Task 25: Update DoD checklist + PR

This task replaces the prior plan's Task 25.

**Files:**
- Modify: `docs/superpowers/handoff-2026-05-21-task15-blocker.md` (final close-out)

- [ ] **Step 1: Add Phase 8 DoD section to handoff (or replace TL;DR)**

Append to the bottom of `handoff-2026-05-21-task15-blocker.md`:

```markdown
## Phase 8 (manual cal CLI) close-out

- Spec: `docs/superpowers/specs/2026-05-21-manual-calibration-cli-design.md` (commit 51cc4a8)
- Plan: `docs/superpowers/plans/2026-05-21-manual-calibration-cli-plan.md`
- BLE `<read:pos>` frame + Dispatcher#handle_read_pos host tests PASS
- ble-client SendBuilder#read_pos / FrameCodec.encode_read_pos / Client servo_frame? extension PASS
- `stackchan-ble-control calibrate` CLI (--align-only / 5-pose / --format) PASS
- HITL Task 23: operator-calibrated SERVO_*_ZERO + RANGE_RAW committed
- Cold-boot torque-OFF status: best-effort only; primary cal path is operator BLE `<torque:off>` per session
```

- [ ] **Step 2: Open PR**

Dispatch general-purpose subagent:

> From `/Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby`, run:
>
> `git push -u origin feat/servo-tuning-and-test-fix`
> then
> `gh pr create --title "feat: servo tuning + manual calibration CLI" --body "$(cat <<'EOF'
> ## Summary
> - New BLE frame `<read:pos>` for raw servo position read
> - `stackchan-ble-control calibrate` CLI: --align-only daily startup + 5-pose anchor recalibration (--samples / --format)
> - Phase 1-7 (cold-boot redesign / normalized protocol / Face::Closed / Dispatcher 6 face / read_pos Branch A fix) all merged in
> - Cold-boot torque-OFF accepted as best-effort; operator BLE-driven manual cal is the primary path (handoff-2026-05-21-task15-blocker)
>
> Specs:
> - docs/superpowers/specs/2026-05-21-cold-boot-torque-off-and-normalized-protocol-design.md
> - docs/superpowers/specs/2026-05-21-manual-calibration-cli-design.md
>
> ## Test plan
> - [x] Host suites: root / picoruby-stackchan-protocol / stackchan-ble-client / stackchan-notifier all green
> - [x] HITL: `calibrate --align-only` reaches device, transitions Face::Closed ↔ Face::Neutral
> - [x] HITL: `calibrate` 5-pose outputs paste-ready constants
> - [x] HITL: After paste + redeploy, `--yaw-left 0 --pitch-up 0` returns head to physical forward
>
> 🤖 Generated with [Claude Code](https://claude.com/claude-code)
> EOF
> )"`

---

## Self-review (post-write)

**Spec coverage check (mapping spec sections → tasks):**
- §Section 1 (操作フロー 2 系統): Task 15 (align-only), Task 16 (full)
- §Section 2 (BLE protocol extension): Task 1-4 (handler + tests + commit)
- §Section 3 (CLI surface): Task 17 (wire-up), flags + exit codes
- §Section 4 (anchor 計算ルール): Task 10 (compute_anchors), Task 11 (classify_verify)
- §Section 5 (実装範囲): mapped to file table at top of this plan
- §Section 6 (テスト戦略): Task 1-3 (dispatcher), Task 5-7 (ble-client), Task 9-16 (calibration unit), Task 23 (HITL)
- §Section 7 DoD #1-3 (read:pos host tests): Task 1-3
- §Section 7 DoD #4 (s.read_pos detail drain): Task 7
- §Section 7 DoD #5 (align-only HITL): Task 23 Step 1
- §Section 7 DoD #6 (5-pose HITL): Task 23 Step 2
- §Section 7 DoD #7 (paste + redeploy → physical forward): Task 23 Step 4-5
- §Section 7 DoD #8 (format json/env): Task 12
- §Section 7 DoD #9 (--samples 3 median): Task 14
- §Section 7 DoD #10 (verify-tolerance branches): Task 11 + Task 16 verify-fail test
- §Section 7 DoD #11 (unknown → exit 6): Task 17 (calibrate case) + Task 16 propagation
- §Section 7 DoD #12 (Ctrl-C → exit 7): Task 17 (Interrupt rescue) + Task 16 propagation test
- §Section 7 DoD #13 (cross-refs updated): Task 20, Task 21

All spec requirements covered.

**Placeholder scan:** None present. All steps have concrete code or commands.

**Type / naming consistency:** verified — `compute_anchors` / `classify_verify` / `sample_pose` / `parse_raw_detail` / `format` / `run_align_only` / `run_full_calibrate` / `UnknownReadError` used consistently across Tasks 9-17.

**Tolerance values (3 / 10):** stated explicitly as `PASS_TOLERANCE=3` / `FAIL_TOLERANCE=10` in Task 11 implementation, used in Task 17 warn message — concrete, not placeholders.

**Test naming:** matches existing `test_*` underscore convention in the codebase (test-unit, not RSpec describe blocks).

---

## Execution handoff

Plan complete and saved to `docs/superpowers/plans/2026-05-21-manual-calibration-cli-plan.md`.

Two execution options:

1. **Subagent-Driven (recommended)** — fresh subagent per task with two-stage review (spec compliance then code quality); fast continuous iteration, no per-task pause
2. **Inline Execution** — execute in this session via `superpowers:executing-plans`; batch with checkpoints

Which approach?
