# Phase A — Face::Sad / Face::Angry Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add two new face classes (`Face::Sad`, `Face::Angry`) end-to-end across device + Mac stack so the kawaii AI robot can emit `Sad` / `Angry` emotion (D3 mapping in spec). One BLE frame `<F:4>` / `<F:5>` switches the LCD to the new face, with deterministic golden-hash regression and an autonomous `rake r2p2:face_verify` task.

**Architecture:** Two new `StackchanProtocol::Face::*` classes added to existing `mrblib/stackchan_protocol.rb` (same file as Neutral/Smile/Joy/Surprised/Closed — keeps Face module cohesive). `Dispatcher::FACE_TABLE` extends from 4 → 6 entries (`"4"=>Sad, "5"=>Angry`). Mac-side `StackchanBleClient::FaceTable::FACE_INDICES` and `StackchanNotifier::CLI::FACES` whitelist extend in lock-step. Regression-locking is via SHA256 of the canonical-serialized `FakeDisplay#calls` array per face — host-only, no on-device framebuffer readback needed (deviation from spec §"Face hash compare" prose: pure-Ruby Face classes are deterministic, so call-sequence SHA is functionally equivalent to RGB565 buffer SHA for catching geometry drift; LCD physical render is implicitly validated once by HITL).

**Tech Stack:** PicoRuby (device mrblib), Ruby (Mac mrbgems + test-unit), Rake (Mac orchestration), BLE NUS (existing combo frame protocol), Digest::SHA256 (stdlib, golden hash).

---

## Scope (Phase A only)

- Add `Face::Sad`, `Face::Angry` classes to `mrbgems/picoruby-stackchan-protocol/mrblib/stackchan_protocol.rb`
- Extend `Dispatcher::FACE_TABLE` to map `"4"=>Face::Sad`, `"5"=>Face::Angry`
- Extend `StackchanBleClient::FaceTable::FACE_INDICES` with `sad: "4"`, `angry: "5"`
- Extend `StackchanNotifier::CLI::FACES` whitelist with `:sad`, `:angry`
- Add golden-hash test infrastructure: `face_golden_test.rb` + `spec/golden/face_<name>.sha256` files for ALL 6 faces (Neutral, Smile, Joy, Surprised, Sad, Angry — locks geometry for existing + new)
- Add Rake helper `face:register_golden` (computes + writes the .sha256 file from current Face class output — used once by claude after HITL calibration)
- Add Rake task `r2p2:face_verify` (host SHA assert + device BLE write → ACK assert)
- HITL: visually verify Sad/Angry on hardware, then register golden hashes

**Out of scope (later phases / never):**
- Frame buffer RGB565 readback on device (LCD driver doesn't expose it)
- Servo / touch / LED color changes for Sad/Angry (Phase E orchestrator decides those)
- Modifying existing Neutral/Smile/Joy/Surprised/Closed geometry (only locking via golden)

---

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `mrbgems/picoruby-stackchan-protocol/mrblib/stackchan_protocol.rb` | Modify | Add `Face::Sad`, `Face::Angry` classes |
| `mrbgems/picoruby-stackchan-protocol/test/stackchan_protocol_test.rb` | Modify | Add geometry assertions for Sad/Angry |
| `mrbgems/picoruby-stackchan-protocol/mrblib/stackchan_protocol/dispatcher.rb` | Modify | Extend `FACE_TABLE` |
| `mrbgems/picoruby-stackchan-protocol/test/dispatcher_test.rb` | Modify | Add `test_F_4_draws_sad`, `test_F_5_draws_angry` |
| `mrbgems/picoruby-stackchan-protocol/test/face_golden_test.rb` | Create | SHA256(canonical(FakeDisplay#calls)) vs golden file per face |
| `mrbgems/picoruby-stackchan-protocol/spec/golden/face_neutral.sha256` | Create | (existing face, locks geometry) |
| `mrbgems/picoruby-stackchan-protocol/spec/golden/face_smile.sha256` | Create | (existing face) |
| `mrbgems/picoruby-stackchan-protocol/spec/golden/face_joy.sha256` | Create | (existing face) |
| `mrbgems/picoruby-stackchan-protocol/spec/golden/face_surprised.sha256` | Create | (existing face) |
| `mrbgems/picoruby-stackchan-protocol/spec/golden/face_sad.sha256` | Create (after HITL) | New face Sad |
| `mrbgems/picoruby-stackchan-protocol/spec/golden/face_angry.sha256` | Create (after HITL) | New face Angry |
| `mrbgems/picoruby-stackchan-protocol/Rakefile` | Modify | Add `face:register_golden FACE=name` helper |
| `pc/stackchan-ble-client/lib/stackchan_ble_client/face_table.rb` | Modify | Add `sad:"4", angry:"5"` |
| `pc/stackchan-ble-client/test/face_table_test.rb` | Modify | Add `test_sad_index_is_four`, `test_angry_index_is_five` |
| `pc/stackchan-notifier/lib/stackchan_notifier/cli.rb` | Modify | Extend `FACES = %i[neutral smile joy surprised sad angry]` |
| `pc/stackchan-notifier/test/cli_test.rb` | Modify | Add `test_face_sad_accepted`, `test_face_angry_accepted` |
| `Rakefile` (root) | Modify | Add `r2p2:face_verify FACE=name` task |

---

## Design notes for the new face classes

### Sad
Mirror of Smile geometry: corners droop **below** the center mouth y instead of above.
```ruby
class Sad < Base
  DELTA_Y = -8   # corner_y = MOUTH_CY - (-8) = 148, below cy=140 → frown
end
```
No `draw_mouth` override needed — `Base#draw_mouth` already supports negative DELTA_Y. Draw call sequence: `[:fill, :draw_ellipse, :draw_ellipse, :draw_line, :draw_line]` (same shape pattern as Smile, just different y coords).

### Angry
Add V-shaped brows (2 short lines forming downward `\__/` chevron above each eye) on top of Neutral mouth. Override `Base#draw` to call super then draw brows.

Coordinates (per `EYE_LEFT_CX=110`, `EYE_RIGHT_CX=210`, `EYE_*_CY=100`):
- Brow constants near top of module (next to MOUTH_HALF_WIDTH etc):
  ```
  BROW_OFFSET_Y    = 18   # 18px above the eye centerline
  BROW_HALF_LENGTH = 16   # horizontal extent each side of eye cx
  BROW_INNER_DROP  = 8    # inner end of brow drops 8px (angry slant)
  ```
- Left brow line: from `(EYE_LEFT_CX - BROW_HALF_LENGTH, EYE_LEFT_CY - BROW_OFFSET_Y)` (outer end, up)  →  `(EYE_LEFT_CX + BROW_HALF_LENGTH, EYE_LEFT_CY - BROW_OFFSET_Y + BROW_INNER_DROP)` (inner end, down)
  = `(94, 82) → (126, 90)`
- Right brow line: mirror — `(EYE_RIGHT_CX - BROW_HALF_LENGTH, EYE_RIGHT_CY - BROW_OFFSET_Y + BROW_INNER_DROP)` (inner end, down)  →  `(EYE_RIGHT_CX + BROW_HALF_LENGTH, EYE_RIGHT_CY - BROW_OFFSET_Y)` (outer end, up)
  = `(194, 90) → (226, 82)`

Draw sequence after override: `[:fill, :draw_ellipse, :draw_ellipse, :draw_line, :draw_line, :draw_line, :draw_line]` — fill, 2 eyes, 2 mouth (neutral straight), 2 brow lines.

### Why this design

- **Visually distinct** from existing 4 faces and from each other on 320×240 LCD (HITL judgment in Task 19, may need tweak then re-register golden)
- **Minimal code surface** — no new module-level helpers, no Base modifications
- **Deterministic** — pure draw call sequences, locked by golden SHA

---

## Task 1: Add `Face::Sad` class (TDD)

**Files:**
- Modify: `mrbgems/picoruby-stackchan-protocol/mrblib/stackchan_protocol.rb` (insert after `Face::Joy`, before `Face::Surprised`)
- Modify: `mrbgems/picoruby-stackchan-protocol/test/stackchan_protocol_test.rb` (append new test class)

- [ ] **Step 1.1: Write the failing tests**

Append to `mrbgems/picoruby-stackchan-protocol/test/stackchan_protocol_test.rb` (after the `FaceSubclassesTest` class):

```ruby
class FaceSadTest < Test::Unit::TestCase
  def setup
    @display = FakeDisplay.new
  end

  def test_sad_delta_y_is_negative_eight
    assert_equal(-8, StackchanProtocol::Face::Sad::DELTA_Y)
  end

  def test_sad_corners_droop_below_center
    StackchanProtocol::Face::Sad.new.draw_mouth(@display)
    # corner_y = MOUTH_CY - (-8) = 140 - (-8) = 148
    # left segment: (135, 148) -> (160, 140)
    assert_equal [135, 148, 160, 140, ILI9342::Color::WHITE], @display.calls[0].last
    # right segment: (160, 140) -> (185, 148)
    assert_equal [160, 140, 185, 148, ILI9342::Color::WHITE], @display.calls[1].last
  end

  def test_sad_draw_sequence_matches_smile_shape
    StackchanProtocol::Face::Sad.new.draw(@display)
    methods = @display.calls.map(&:first)
    assert_equal [:fill, :draw_ellipse, :draw_ellipse, :draw_line, :draw_line], methods
  end
end
```

- [ ] **Step 1.2: Run tests to verify they fail**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/mrbgems/picoruby-stackchan-protocol
bundle exec rake test TESTOPTS="--name=/FaceSadTest/"
```

Expected: 3 FAILs with `NameError: uninitialized constant StackchanProtocol::Face::Sad`.

- [ ] **Step 1.3: Add the Sad class**

In `mrbgems/picoruby-stackchan-protocol/mrblib/stackchan_protocol.rb`, after the `class Joy < Base ... end` block (around line 84) and before `class Surprised < Base` (around line 86), insert:

```ruby
    class Sad < Base
      DELTA_Y = -8
    end
```

- [ ] **Step 1.4: Run tests to verify they pass**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/mrbgems/picoruby-stackchan-protocol
bundle exec rake test TESTOPTS="--name=/FaceSadTest/"
```

Expected: 3 PASSes.

- [ ] **Step 1.5: Run full mrbgem test suite to verify no regression**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/mrbgems/picoruby-stackchan-protocol
bundle exec rake test
```

Expected: all tests PASS (existing + 3 new).

- [ ] **Step 1.6: Commit**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby
git add mrbgems/picoruby-stackchan-protocol/mrblib/stackchan_protocol.rb \
        mrbgems/picoruby-stackchan-protocol/test/stackchan_protocol_test.rb
git commit -m "feat(face): add Face::Sad with DELTA_Y=-8 frown geometry"
```

---

## Task 2: Add `Face::Angry` class with brow lines (TDD)

**Files:**
- Modify: `mrbgems/picoruby-stackchan-protocol/mrblib/stackchan_protocol.rb` (add brow constants + Angry class)
- Modify: `mrbgems/picoruby-stackchan-protocol/test/stackchan_protocol_test.rb` (new test class)

- [ ] **Step 2.1: Write the failing tests**

Append to `mrbgems/picoruby-stackchan-protocol/test/stackchan_protocol_test.rb`:

```ruby
class FaceAngryTest < Test::Unit::TestCase
  def setup
    @display = FakeDisplay.new
  end

  def test_brow_constants_have_expected_values
    assert_equal 18, StackchanProtocol::Face::BROW_OFFSET_Y
    assert_equal 16, StackchanProtocol::Face::BROW_HALF_LENGTH
    assert_equal 8,  StackchanProtocol::Face::BROW_INNER_DROP
  end

  def test_draw_sequence_is_neutral_plus_two_brow_lines
    StackchanProtocol::Face::Angry.new.draw(@display)
    methods = @display.calls.map(&:first)
    # fill, 2 eyes, 2 neutral mouth lines, 2 brow lines
    assert_equal [:fill, :draw_ellipse, :draw_ellipse, :draw_line, :draw_line, :draw_line, :draw_line], methods
  end

  def test_left_brow_line_slants_down_inward
    StackchanProtocol::Face::Angry.new.draw(@display)
    line_calls = @display.calls.select { |c| c.first == :draw_line }
    # last two draw_line calls are brows (after the two mouth lines)
    left_brow = line_calls[2].last
    # outer end (94, 82) → inner end (126, 90)
    assert_equal [94, 82, 126, 90, ILI9342::Color::WHITE], left_brow
  end

  def test_right_brow_line_slants_down_inward
    StackchanProtocol::Face::Angry.new.draw(@display)
    line_calls = @display.calls.select { |c| c.first == :draw_line }
    right_brow = line_calls[3].last
    # inner end (194, 90) → outer end (226, 82)
    assert_equal [194, 90, 226, 82, ILI9342::Color::WHITE], right_brow
  end

  def test_angry_neutral_mouth_geometry_preserved
    StackchanProtocol::Face::Angry.new.draw(@display)
    line_calls = @display.calls.select { |c| c.first == :draw_line }
    # first two draw_line calls are the neutral mouth (DELTA_Y=0)
    assert_equal [135, 140, 160, 140, ILI9342::Color::WHITE], line_calls[0].last
    assert_equal [160, 140, 185, 140, ILI9342::Color::WHITE], line_calls[1].last
  end
end
```

- [ ] **Step 2.2: Run tests to verify they fail**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/mrbgems/picoruby-stackchan-protocol
bundle exec rake test TESTOPTS="--name=/FaceAngryTest/"
```

Expected: 5 FAILs (`uninitialized constant ::Angry`, brow constants missing).

- [ ] **Step 2.3: Add brow constants and Angry class**

In `mrbgems/picoruby-stackchan-protocol/mrblib/stackchan_protocol.rb`:

(a) Add brow constants near the existing geometry constants (just above the `class Base` definition, after `SURPRISED_MOUTH_HALF_H = 12` — around line 28):

```ruby
    # Angry brow geometry — V-shaped chevrons above each eye, inner ends drop.
    BROW_OFFSET_Y    = 18   # baseline 18px above eye centerline
    BROW_HALF_LENGTH = 16   # horizontal extent each side of eye cx
    BROW_INNER_DROP  = 8    # inner end of brow drops 8px relative to outer end
```

(b) Append the `Angry` class after `Sad` (and before `Surprised`):

```ruby
    class Angry < Base
      DELTA_Y = 0   # neutral mouth

      def draw(display)
        super
        # Left brow: outer end up, inner end down (V-slant toward bridge of nose).
        display.draw_line(
          EYE_LEFT_CX - BROW_HALF_LENGTH, EYE_LEFT_CY - BROW_OFFSET_Y,
          EYE_LEFT_CX + BROW_HALF_LENGTH, EYE_LEFT_CY - BROW_OFFSET_Y + BROW_INNER_DROP,
          EYE_COLOR
        )
        # Right brow: mirror — inner end down, outer end up.
        display.draw_line(
          EYE_RIGHT_CX - BROW_HALF_LENGTH, EYE_RIGHT_CY - BROW_OFFSET_Y + BROW_INNER_DROP,
          EYE_RIGHT_CX + BROW_HALF_LENGTH, EYE_RIGHT_CY - BROW_OFFSET_Y,
          EYE_COLOR
        )
      end
    end
```

- [ ] **Step 2.4: Run tests to verify they pass**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/mrbgems/picoruby-stackchan-protocol
bundle exec rake test TESTOPTS="--name=/FaceAngryTest/"
```

Expected: 5 PASSes.

- [ ] **Step 2.5: Run full test suite**

```bash
bundle exec rake test
```

Expected: all PASS.

- [ ] **Step 2.6: Commit**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby
git add mrbgems/picoruby-stackchan-protocol/mrblib/stackchan_protocol.rb \
        mrbgems/picoruby-stackchan-protocol/test/stackchan_protocol_test.rb
git commit -m "feat(face): add Face::Angry with V-shaped brow lines above neutral mouth"
```

---

## Task 3: Extend `Dispatcher::FACE_TABLE` (TDD)

**Files:**
- Modify: `mrbgems/picoruby-stackchan-protocol/mrblib/stackchan_protocol/dispatcher.rb` (FACE_TABLE entries)
- Modify: `mrbgems/picoruby-stackchan-protocol/test/dispatcher_test.rb` (add F:4, F:5 dispatch tests)

- [ ] **Step 3.1: Write the failing tests**

Append to `mrbgems/picoruby-stackchan-protocol/test/dispatcher_test.rb`, inside the existing `DispatcherFaceTest` class (after `test_F_3_draws_surprised`):

```ruby
  def test_F_4_draws_sad
    @disp.handle({ "F" => "4" })
    # Sad call sequence is identical shape to Smile, but corner y is 148 not 132.
    line = @display.calls.select { |c| c.first == :draw_line }.first.last
    assert_equal 148, line[1]
  end

  def test_F_5_draws_angry
    @disp.handle({ "F" => "5" })
    methods = @display.calls.map(&:first)
    # fill, 2 eyes, 2 neutral mouth, 2 brow lines
    assert_equal [:fill, :draw_ellipse, :draw_ellipse, :draw_line, :draw_line, :draw_line, :draw_line], methods
  end

  def test_F_4_and_F_5_write_ack
    @disp.handle({ "F" => "4" })
    assert_equal ["."], @stdout.writes
    @stdout.writes.clear if @stdout.writes.respond_to?(:clear)
  end
```

- [ ] **Step 3.2: Run tests to verify they fail**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/mrbgems/picoruby-stackchan-protocol
bundle exec rake test TESTOPTS="--name=/test_F_4|test_F_5/"
```

Expected: FAILs — `F:4` and `F:5` are unknown, dispatcher writes `?` (ERROR_BYTE) instead of expected face draw calls.

- [ ] **Step 3.3: Extend FACE_TABLE**

In `mrbgems/picoruby-stackchan-protocol/mrblib/stackchan_protocol/dispatcher.rb`, modify the `FACE_TABLE` constant (lines 6-11):

```ruby
    FACE_TABLE = {
      "0" => Face::Neutral,
      "1" => Face::Smile,
      "2" => Face::Joy,
      "3" => Face::Surprised,
      "4" => Face::Sad,
      "5" => Face::Angry,
    }.freeze
```

- [ ] **Step 3.4: Run tests to verify they pass**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/mrbgems/picoruby-stackchan-protocol
bundle exec rake test
```

Expected: all PASS (existing + new F:4/F:5 dispatch).

- [ ] **Step 3.5: Commit**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby
git add mrbgems/picoruby-stackchan-protocol/mrblib/stackchan_protocol/dispatcher.rb \
        mrbgems/picoruby-stackchan-protocol/test/dispatcher_test.rb
git commit -m "feat(dispatcher): map F:4 -> Face::Sad, F:5 -> Face::Angry"
```

---

## Task 4: Extend Mac-side `FaceTable::FACE_INDICES` (TDD)

**Files:**
- Modify: `pc/stackchan-ble-client/lib/stackchan_ble_client/face_table.rb`
- Modify: `pc/stackchan-ble-client/test/face_table_test.rb`

- [ ] **Step 4.1: Write the failing tests**

Append to `pc/stackchan-ble-client/test/face_table_test.rb`, inside the existing `FaceTableTest` class (before the `test_unknown_face_raises_key_error`):

```ruby
  def test_sad_index_is_four
    assert_equal "4", StackchanBleClient::FaceTable::FACE_INDICES.fetch(:sad)
  end

  def test_angry_index_is_five
    assert_equal "5", StackchanBleClient::FaceTable::FACE_INDICES.fetch(:angry)
  end
```

- [ ] **Step 4.2: Run tests to verify they fail**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/pc/stackchan-ble-client
bundle exec rake test TESTOPTS="--name=/test_sad_index|test_angry_index/"
```

Expected: FAILs — `KeyError: key not found: :sad`.

- [ ] **Step 4.3: Extend FACE_INDICES**

In `pc/stackchan-ble-client/lib/stackchan_ble_client/face_table.rb`, modify the hash:

```ruby
module StackchanBleClient
  module FaceTable
    FACE_INDICES = {
      neutral:   "0",
      smile:     "1",
      joy:       "2",
      surprised: "3",
      sad:       "4",
      angry:     "5",
    }.freeze
  end
end
```

- [ ] **Step 4.4: Run tests to verify they pass**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/pc/stackchan-ble-client
bundle exec rake test
```

Expected: all PASS (existing 5 + new 2).

- [ ] **Step 4.5: Commit**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby
git add pc/stackchan-ble-client/lib/stackchan_ble_client/face_table.rb \
        pc/stackchan-ble-client/test/face_table_test.rb
git commit -m "feat(ble-client): add sad=4 / angry=5 to FACE_INDICES"
```

---

## Task 5: Extend `StackchanNotifier::CLI::FACES` whitelist (TDD)

**Files:**
- Modify: `pc/stackchan-notifier/lib/stackchan_notifier/cli.rb`
- Modify: `pc/stackchan-notifier/test/cli_test.rb`

- [ ] **Step 5.1: Write the failing tests**

Append to `pc/stackchan-notifier/test/cli_test.rb`, inside the existing `CLITest` class (after `test_missing_face_exits_2_with_stderr_message`):

```ruby
  def test_face_sad_accepted
    code = run_cli(%w[--face sad --left_led red,solid])
    assert_equal 0, code, @stderr.string
    _, tuple = @sent.first
    assert_equal :sad, tuple[1]
  end

  def test_face_angry_accepted
    code = run_cli(%w[--face angry --left_led red,solid])
    assert_equal 0, code, @stderr.string
    _, tuple = @sent.first
    assert_equal :angry, tuple[1]
  end

  def test_face_unknown_rejected_lists_sad_and_angry
    code = run_cli(%w[--face confused --left_led red,solid])
    assert_equal 2, code
    assert_match(/sad/, @stderr.string)
    assert_match(/angry/, @stderr.string)
  end
```

- [ ] **Step 5.2: Run tests to verify they fail**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/pc/stackchan-notifier
bundle exec rake test TESTOPTS="--name=/test_face_sad|test_face_angry|test_face_unknown_rejected_lists/"
```

Expected: FAILs — `--face required (one of neutral / smile / joy / surprised)` (sad/angry not in whitelist).

- [ ] **Step 5.3: Extend FACES whitelist**

In `pc/stackchan-notifier/lib/stackchan_notifier/cli.rb`, modify line 16:

```ruby
    FACES = %i[neutral smile joy surprised sad angry].freeze
```

- [ ] **Step 5.4: Run tests to verify they pass**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/pc/stackchan-notifier
bundle exec rake test
```

Expected: all PASS.

- [ ] **Step 5.5: Commit**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby
git add pc/stackchan-notifier/lib/stackchan_notifier/cli.rb \
        pc/stackchan-notifier/test/cli_test.rb
git commit -m "feat(notifier): accept --face sad / --face angry"
```

---

## Task 6: Add golden-hash test infrastructure (TDD)

**Files:**
- Create: `mrbgems/picoruby-stackchan-protocol/test/face_golden_test.rb`
- Create: `mrbgems/picoruby-stackchan-protocol/spec/golden/.keep`

The golden test loads each face's expected SHA from `spec/golden/face_<name>.sha256`, runs `Face::<Name>.new.draw(FakeDisplay.new)`, canonicalizes `@display.calls` to a deterministic string, hashes it with SHA256, and asserts equality. If the golden file is missing, the test OMITs (Test::Unit's skip) with the SHA to write — claude uses this output to register after HITL approval.

- [ ] **Step 6.1: Write the failing test**

Create `mrbgems/picoruby-stackchan-protocol/test/face_golden_test.rb`:

```ruby
require "test_helper"
require "digest"

# Lock the call-sequence SHA of each Face class against a golden file in
# spec/golden/face_<name>.sha256. Deviation from spec's "RGB565 buffer SHA"
# wording: pure-Ruby Face classes are deterministic in their draw call
# sequence, so a SHA over canonicalized calls catches any geometry drift
# (constants, formulas, method overrides). LCD readback is not available on
# device. HITL calibration validates visual correctness once, then the SHA
# locks the geometry for all future regression runs.
class FaceGoldenTest < Test::Unit::TestCase
  GOLDEN_DIR = File.expand_path("../spec/golden", __dir__)

  FACE_CASES = {
    neutral:   StackchanProtocol::Face::Neutral,
    smile:     StackchanProtocol::Face::Smile,
    joy:       StackchanProtocol::Face::Joy,
    surprised: StackchanProtocol::Face::Surprised,
    sad:       StackchanProtocol::Face::Sad,
    angry:     StackchanProtocol::Face::Angry,
  }.freeze

  # Deterministic string for a single FakeDisplay#calls entry:
  #   "method_name|arg0,arg1,...,argN-1,{fill:true/false}"
  # The trailing keyword-arg hash (when present) is serialized in key:value
  # form so different Ruby hash insertion orders are still equal.
  def self.serialize_call(call)
    method, args = call
    parts = args.map do |a|
      case a
      when Hash
        "{" + a.sort_by { |k, _| k.to_s }.map { |k, v| "#{k}:#{v}" }.join(",") + "}"
      else
        a.to_s
      end
    end
    "#{method}|#{parts.join(",")}"
  end

  def self.canonical_dump(calls)
    calls.map { |c| serialize_call(c) }.join("\n")
  end

  def self.compute_sha(face_class)
    display = FakeDisplay.new
    face_class.new.draw(display)
    Digest::SHA256.hexdigest(canonical_dump(display.calls))
  end

  FACE_CASES.each do |name, klass|
    define_method("test_#{name}_matches_golden") do
      golden_path = File.join(GOLDEN_DIR, "face_#{name}.sha256")
      actual_sha  = self.class.compute_sha(klass)
      unless File.exist?(golden_path)
        omit "no golden registered for face_#{name}; current SHA=#{actual_sha}; " \
             "HITL-approve visual then run `rake face:register_golden FACE=#{name}` to register"
      end
      expected_sha = File.read(golden_path).strip
      assert_equal expected_sha, actual_sha,
        "Face::#{klass.name.split('::').last} call-sequence SHA drift. " \
        "If geometry change is intentional, HITL-revalidate then re-register golden."
    end
  end
end
```

Create `mrbgems/picoruby-stackchan-protocol/spec/golden/.keep` (empty file, ensures dir is tracked even before any golden registered):

```bash
mkdir -p /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/mrbgems/picoruby-stackchan-protocol/spec/golden
touch /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/mrbgems/picoruby-stackchan-protocol/spec/golden/.keep
```

- [ ] **Step 6.2: Run the new test (all 6 should OMIT since no golden exists yet)**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/mrbgems/picoruby-stackchan-protocol
bundle exec rake test TESTOPTS="--name=/FaceGoldenTest/"
```

Expected: 6 OMITs, each printing a line like `no golden registered for face_neutral; current SHA=<64-hex>; HITL-approve visual then run \`rake face:register_golden FACE=neutral\` to register`.

Test::Unit OMIT counts as neither PASS nor FAIL — the run exits 0. Capture the 6 SHA strings from the output for Task 7.

- [ ] **Step 6.3: Commit (infrastructure only, no golden files yet)**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby
git add mrbgems/picoruby-stackchan-protocol/test/face_golden_test.rb \
        mrbgems/picoruby-stackchan-protocol/spec/golden/.keep
git commit -m "test(face): add golden-SHA regression infra for face draw sequences"
```

---

## Task 7: Add `face:register_golden` Rake helper + register goldens for existing 4 faces (no HITL needed)

**Files:**
- Modify: `mrbgems/picoruby-stackchan-protocol/Rakefile` (add `face:register_golden` task)
- Create: `spec/golden/face_neutral.sha256`, `spec/golden/face_smile.sha256`, `spec/golden/face_joy.sha256`, `spec/golden/face_surprised.sha256` (via the helper)

The 4 existing faces (Neutral, Smile, Joy, Surprised) are already shipped on device and HITL-validated in prior phases — their goldens can be registered immediately without re-calibration. Sad/Angry goldens wait until Task 19 HITL.

- [ ] **Step 7.1: Read the current Rakefile to find insertion point**

```bash
cat /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/mrbgems/picoruby-stackchan-protocol/Rakefile
```

Note the existing namespace structure.

- [ ] **Step 7.2: Add the `face:register_golden` task**

Append to `mrbgems/picoruby-stackchan-protocol/Rakefile`:

```ruby
namespace :face do
  desc "compute SHA256 of Face::<NAME>.new.draw call sequence and write spec/golden/face_<NAME>.sha256 (FACE=neutral|smile|joy|surprised|sad|angry)"
  task :register_golden do
    name = ENV.fetch("FACE") { abort "FACE=<name> required" }
    $LOAD_PATH.unshift(File.expand_path("mrblib", __dir__))
    $LOAD_PATH.unshift(File.expand_path("test",   __dir__))
    require "stackchan_protocol"
    require "fake_display"
    require "digest"
    # Reuse FaceGoldenTest canonical_dump so registration and assertion stay
    # in lock-step (single source of truth for serialization format).
    require "face_golden_test"
    klass = FaceGoldenTest::FACE_CASES.fetch(name.to_sym) do
      abort "unknown FACE=#{name}; one of: #{FaceGoldenTest::FACE_CASES.keys.join(' / ')}"
    end
    sha = FaceGoldenTest.compute_sha(klass)
    out = File.expand_path("spec/golden/face_#{name}.sha256", __dir__)
    File.write(out, sha + "\n")
    puts "[face:register_golden] wrote #{out} sha=#{sha}"
  end
end
```

Note: `require "face_golden_test"` loads the test file as a library — `Test::Unit` test classes are still just plain classes, so calling `FaceGoldenTest.compute_sha(klass)` works without running the suite. We push both `mrblib` and `test` onto `$LOAD_PATH` because `face_golden_test.rb` does `require "test_helper"` which lives in `test/`.

But `test_helper.rb` may have side effects (running tests on load). Verify:

```bash
cat /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/mrbgems/picoruby-stackchan-protocol/test/test_helper.rb
```

If `test_helper.rb` just sets up `$LOAD_PATH` + requires `stackchan_protocol`, the require is safe. If it auto-runs tests, refactor the SHA helper out of `FaceGoldenTest` into a plain module `FaceGoldenHash` in `test/face_golden_hash.rb` (no Test::Unit inheritance), and have `face_golden_test.rb` require + delegate. Choose based on what's in `test_helper.rb` — if in doubt, prefer the extraction (safer).

- [ ] **Step 7.3: Register golden for `neutral`**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/mrbgems/picoruby-stackchan-protocol
bundle exec rake face:register_golden FACE=neutral
```

Expected output: `[face:register_golden] wrote .../spec/golden/face_neutral.sha256 sha=<64-hex>`.

- [ ] **Step 7.4: Register golden for `smile`, `joy`, `surprised`**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/mrbgems/picoruby-stackchan-protocol
bundle exec rake face:register_golden FACE=smile
bundle exec rake face:register_golden FACE=joy
bundle exec rake face:register_golden FACE=surprised
```

Each should write a `.sha256` file. Verify 4 files now exist:

```bash
ls -la mrbgems/picoruby-stackchan-protocol/spec/golden/
```

Expected: 4 `face_*.sha256` files + `.keep`.

- [ ] **Step 7.5: Re-run golden test — 4 PASS, 2 OMIT (sad/angry still unregistered)**

```bash
bundle exec rake test TESTOPTS="--name=/FaceGoldenTest/"
```

Expected: `test_neutral_matches_golden`, `test_smile_...`, `test_joy_...`, `test_surprised_...` all PASS. `test_sad_...` and `test_angry_...` OMIT with SHA in message.

- [ ] **Step 7.6: Commit**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby
git add mrbgems/picoruby-stackchan-protocol/Rakefile \
        mrbgems/picoruby-stackchan-protocol/spec/golden/face_neutral.sha256 \
        mrbgems/picoruby-stackchan-protocol/spec/golden/face_smile.sha256 \
        mrbgems/picoruby-stackchan-protocol/spec/golden/face_joy.sha256 \
        mrbgems/picoruby-stackchan-protocol/spec/golden/face_surprised.sha256
git commit -m "test(face): register goldens for neutral/smile/joy/surprised + add face:register_golden rake helper"
```

---

## Task 8: Add root `r2p2:face_verify` Rake task

**Files:**
- Modify: `/Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/Rakefile` (add task in `namespace :r2p2`)

The task does two things:
1. **Host SHA assert** — run `bundle exec rake test TESTOPTS="--name=/FaceGoldenTest#test_<face>_matches_golden/"` in the mrbgem dir; FAIL = exit non-zero
2. **Device BLE round-trip** — reuse the existing `ble_control_smoke` pattern (upload application.mrb, reset, wait, send `<F:<idx>>` combo via `stackchan-ble-control`, assert ACK)

For Phase A we'll keep the device leg using the existing `ble_control_smoke` pattern as-is and just pass `FACE=<name>` through. The visual confirmation comes from HITL in Task 19; the ACK assert (already enforced by `ble_control_smoke` propagating exit code) verifies the dispatcher routed `F:<idx>` without parse error.

- [ ] **Step 8.1: Add the task**

Append to the root `Rakefile` inside `namespace :r2p2` (just before the closing `end` of the namespace, around line 224):

```ruby
  desc 'face verify: host golden-SHA assert + device BLE write + ACK (FACE=neutral|smile|joy|surprised|sad|angry, requires registered golden)'
  task :face_verify do
    face = ENV.fetch('FACE') { abort 'FACE=<name> required for r2p2:face_verify' }
    valid_faces = %w[neutral smile joy surprised sad angry]
    abort "unknown FACE=#{face}; one of: #{valid_faces.join(' / ')}" unless valid_faces.include?(face)

    # Leg 1: host golden SHA — fast (<2s), no device touch.
    Bundler.with_unbundled_env do
      Dir.chdir(File.expand_path('mrbgems/picoruby-stackchan-protocol', __dir__)) do
        ok = system('bundle', 'exec', 'rake', 'test',
                    "TESTOPTS=--name=/FaceGoldenTest#test_#{face}_matches_golden/")
        abort "[face_verify] host golden SHA FAIL for face=#{face}" unless ok
      end
    end
    puts "[face_verify] host golden SHA PASS for face=#{face}"

    # Leg 2: device BLE round-trip — slower (~20-30s with autostart wait).
    ENV['FACE'] = face
    ENV['COLOR'] ||= 'white'
    ENV['MODE']  ||= 'solid'
    ENV['SIDE']  ||= 'both'
    Rake::Task['r2p2:ble_control_smoke'].invoke

    puts "[face_verify] PASS — face=#{face} host SHA matched + device ACK received"
  end
```

- [ ] **Step 8.2: Smoke test the task on an already-registered face (no device touch needed for the host leg)**

To validate **only** the host SHA assert path without flashing the device, temporarily run just the test invocation directly:

```bash
cd /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/mrbgems/picoruby-stackchan-protocol
bundle exec rake test TESTOPTS="--name=/FaceGoldenTest#test_neutral_matches_golden/"
```

Expected: 1 test, 1 PASS, 0 failures, exit 0.

(The device leg requires hardware + flashed app.mrb; we'll exercise it in Task 19 HITL.)

- [ ] **Step 8.3: Commit**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby
git add Rakefile
git commit -m "feat(rake): add r2p2:face_verify task (host SHA + device BLE ACK)"
```

---

## Task 9: Verify ALL non-Phase-A regression — full host test suite across 3 gems

After all source/protocol changes, run every gem's full test suite to confirm no Phase A change broke anything.

- [ ] **Step 9.1: Run picoruby-stackchan-protocol full suite**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/mrbgems/picoruby-stackchan-protocol
bundle exec rake test
```

Expected: all PASS or OMIT (the OMITs are sad/angry goldens still unregistered — that's expected for Phase A pre-HITL state).

- [ ] **Step 9.2: Run stackchan-ble-client full suite**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/pc/stackchan-ble-client
bundle exec rake test
```

Expected: all PASS (no OMIT).

- [ ] **Step 9.3: Run stackchan-notifier full suite**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/pc/stackchan-notifier
bundle exec rake test
```

Expected: all PASS.

- [ ] **Step 9.4: If any test FAILed, stop and triage. If all PASS/OMIT, proceed to Task 10.**

---

## Task 10 (HITL gate): Flash device + visual confirmation + register Sad/Angry goldens

This is the only HITL step in Phase A. claude prepares the device, then asks the user to look at the LCD and approve. After approval, claude registers the goldens.

- [ ] **Step 10.1: Flash the updated firmware to device**

Delegate to subagent (per CLAUDE.md "rake は subagent foreground で 1 個ずつ"):

Spawn a `general-purpose` subagent (model: haiku) with this prompt:

> Run `cd /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby && rake r2p2:build_flash` in the foreground. Use a 600000ms timeout. Report only pass/fail and the last 30 lines of output. Do NOT modify any code during this run — this is a verify-only deploy.

Expected: BUILD PASS + FLASH PASS, exit 0. If FAIL, triage (likely sdkconfig drift; see CLAUDE.md "sdkconfig fragment 編集後は自動再生成").

- [ ] **Step 10.2: Upload `application.rb` autostart payload**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby
rake r2p2:upload SRC=mrbgems/picoruby-stackchan-protocol/examples/application.rb DST=/home/app.rb
```

Wait 8-12s for boot per CLAUDE.md PicoModem upload timing rule.

- [ ] **Step 10.3: Dispatch BLE write for Sad, observe LCD**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby
FACE=sad COLOR=blue MODE=breathing SIDE=both rake r2p2:ble_control_smoke
```

Expected output ends with `[smoke] PASS — face=sad LED=blue breathing (side=both) — visual check please`.

- [ ] **Step 10.4: Ask the user to visually confirm Sad face**

Send a message to the user (this is the HITL gate):

> Phase A device test: Sad face dispatched (`<F:4>`). Please look at the LCD and confirm:
> 1. Mouth corners droop **down** (frown shape, opposite of smile)
> 2. Eyes are unchanged (two small white dots)
> 3. No brows visible
> Reply OK / not OK. If not OK, describe what looks wrong (corner too steep? mouth wrong position? wrong shape entirely?).

Wait for user reply. If `not OK`, stop and discuss design tweak (likely DELTA_Y value adjustment in Task 1); after tweak, repeat Tasks 1-9 then return to 10.3.

- [ ] **Step 10.5: Dispatch BLE write for Angry, observe LCD**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby
FACE=angry COLOR=red MODE=blink SIDE=both rake r2p2:ble_control_smoke
```

Expected: `[smoke] PASS — face=angry LED=red blink ...`.

- [ ] **Step 10.6: Ask the user to visually confirm Angry face**

> Phase A device test: Angry face dispatched (`<F:5>`). Please look at the LCD and confirm:
> 1. Two V-shaped brows above eyes (inner ends pointing down/inward — like ╲ ╱)
> 2. Mouth is a straight neutral line (no curve)
> 3. Eyes unchanged
> Reply OK / not OK. If not OK, describe what's wrong (brow too high/low? slant wrong? lines too short?).

Wait for user reply. Same tweak loop as 10.4 on "not OK".

- [ ] **Step 10.7: Register goldens for Sad and Angry**

After **both** Sad and Angry are HITL-approved:

```bash
cd /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/mrbgems/picoruby-stackchan-protocol
bundle exec rake face:register_golden FACE=sad
bundle exec rake face:register_golden FACE=angry
```

Each prints `[face:register_golden] wrote .../face_sad.sha256 sha=<64-hex>`.

- [ ] **Step 10.8: Re-run full FaceGoldenTest — all 6 PASS now**

```bash
bundle exec rake test TESTOPTS="--name=/FaceGoldenTest/"
```

Expected: 6 tests, 6 PASS, 0 OMIT, 0 FAIL.

- [ ] **Step 10.9: Run end-to-end `r2p2:face_verify` for sad and angry to validate the full task path**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby
rake r2p2:face_verify FACE=sad
```

Expected output ends with `[face_verify] PASS — face=sad host SHA matched + device ACK received`.

```bash
rake r2p2:face_verify FACE=angry
```

Expected: same PASS line for angry.

- [ ] **Step 10.10: Commit golden files**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby
git add mrbgems/picoruby-stackchan-protocol/spec/golden/face_sad.sha256 \
        mrbgems/picoruby-stackchan-protocol/spec/golden/face_angry.sha256
git commit -m "test(face): register HITL-approved goldens for sad and angry"
```

---

## Task 11: Phase A wrap-up — update memory + handoff

- [ ] **Step 11.1: Write Phase A completion memory**

Create `/Users/bash/.claude/projects/-Users-bash-dev-src-github-com-bash0C7-stackchan-picoruby/memory/project_kawaii_ai_phase_a_complete.md`:

```markdown
---
name: kawaii-ai-phase-a-complete
description: Phase A (Face::Sad/Angry + golden-SHA infra) complete YYYY-MM-DD. F:4=Sad, F:5=Angry. Goldens registered for all 6 faces. r2p2:face_verify FACE=<name> validates host SHA + device ACK.
metadata:
  type: project
---

Phase A of [[kawaii-ai-robot-design]] complete on YYYY-MM-DD (replace with actual date at commit time).

**Shipped:**
- `Face::Sad` (DELTA_Y=-8, frown) at `mrbgems/picoruby-stackchan-protocol/mrblib/stackchan_protocol.rb`
- `Face::Angry` (V-brows above neutral mouth, brow constants in same file)
- `Dispatcher::FACE_TABLE` extends: `"4"=>Sad, "5"=>Angry`
- `StackchanBleClient::FaceTable::FACE_INDICES` adds `sad: "4", angry: "5"`
- `StackchanNotifier::CLI::FACES` accepts `:sad, :angry`
- Golden-SHA test infra: `test/face_golden_test.rb` + `spec/golden/face_*.sha256` for all 6 faces
- `rake face:register_golden FACE=<name>` helper (mrbgem-local)
- `rake r2p2:face_verify FACE=<name>` task (host SHA + device ACK)

**HITL calibration locked:** sad/angry visual approved YYYY-MM-DD, goldens registered. Future regression detection: if `FaceGoldenTest` FAILs after a code change, geometry drift is intentional → re-HITL + re-register, or unintentional → revert.

**Next:** [[kawaii-ai-phase-b-servo]] (picoruby-scservo + dispatcher X/Y/V/H/Q keys).
```

Replace `YYYY-MM-DD` with actual dates at write time.

- [ ] **Step 11.2: Update MEMORY.md index**

Append to `/Users/bash/.claude/projects/-Users-bash-dev-src-github-com-bash0C7-stackchan-picoruby/memory/MEMORY.md`:

```markdown
- [Kawaii AI Phase A complete](project_kawaii_ai_phase_a_complete.md) — Sad/Angry shipped, F:4/F:5, golden SHA infra for all 6 faces, r2p2:face_verify wired
```

- [ ] **Step 11.3: Final commit**

```bash
cd /Users/bash/.claude/  # NOTE: memory files live in ~/.claude/ NOT in the project repo
git -C /Users/bash/.claude add projects/-Users-bash-dev-src-github-com-bash0C7-stackchan-picoruby/memory/project_kawaii_ai_phase_a_complete.md \
                              projects/-Users-bash-dev-src-github-com-bash0C7-stackchan-picoruby/memory/MEMORY.md 2>/dev/null || true
```

If `~/.claude/` is a git repo (per CLAUDE.md "dotfiles location" — managed via GNU stow from iCloud), commit there per its own conventions. If not a git repo, just save the files in-place; no commit needed.

- [ ] **Step 11.4: Report to user**

Send one short status line to the user:

> Phase A 完了。Sad/Angry face shipped、golden SHA 全 6 face 登録、`rake r2p2:face_verify FACE=<name>` で autonomous regression OK。次は Phase B (servo) の plan 書きに入る？

---

## Self-review (against spec §7 Phase A row)

Spec §7 row Phase A wording:
> 実装: `Face::Sad`, `Face::Angry` を `picoruby-stackchan-protocol/mrblib/` に追加、`FACE_TABLE` 拡張、ble-client / notifier の `--face` 候補拡張
> autonomous verify: `rake r2p2:face_verify FACE=sad` — Mac BLE write → ACK assert + frame buffer SHA hash compare vs `spec/golden/face_sad.sha256`
> HITL 1 回だけ: 初回 calibration: 「sad / angry 見た目 OK?」HITL 確認 → hash 登録

Coverage check:
- ✅ Face::Sad in mrblib → Task 1
- ✅ Face::Angry in mrblib → Task 2
- ✅ FACE_TABLE extension → Task 3
- ✅ ble-client face candidate extension → Task 4
- ✅ notifier --face candidate extension → Task 5
- ✅ `rake r2p2:face_verify FACE=sad` task → Task 8
- ✅ Mac BLE write → ACK assert → Task 8 (delegates to `r2p2:ble_control_smoke` which propagates CLI exit code)
- ✅ frame buffer SHA hash compare vs `spec/golden/face_sad.sha256` → Task 6 (golden infra) + Task 7 (4 registrations) + Task 10 (sad/angry registrations after HITL)
  - **Deviation noted:** call-sequence SHA, not RGB565 buffer SHA. Documented inline at top of `face_golden_test.rb`. Rationale: pure Ruby Face classes are deterministic on call sequence, LCD has no readback API, HITL implicitly validates LCD render. Functionally equivalent for catching geometry drift.
- ✅ HITL 1 回 sad/angry 見た目 OK 確認 → Task 10.4 + 10.6
- ✅ hash 登録 → Task 10.7

Spec also notes Phase 1-3 existing BLE/face/LED hash 登録 / 物理方向 calibration も Phase A 開始時にまとめて 1 回やる:
- ✅ Existing 4 face goldens registered without HITL re-calibration → Task 7 (covered by note "shipped on device and HITL-validated in prior phases")

Type/method-name consistency:
- `FACE_TABLE` keys are string `"0".."5"` everywhere (matches existing pattern)
- `FACE_INDICES` keys are symbol `:neutral..:angry` with string `"0".."5"` values everywhere
- `FACES` whitelist is array of symbols, matches `FACE_INDICES` keys
- `Face::Sad` and `Face::Angry` constant names consistent across all task code blocks
- `BROW_OFFSET_Y / BROW_HALF_LENGTH / BROW_INNER_DROP` constant names referenced identically in implementation + test code
- `FaceGoldenTest::FACE_CASES` hash + `FaceGoldenTest.compute_sha` class method referenced identically in Task 6 source + Task 7 rake task

Placeholder scan: no "TBD/TODO/etc"; all code blocks complete; YYYY-MM-DD placeholder in memory file explicitly flagged with "replace with actual date".

Scope check: 11 tasks, all within Phase A boundary. No servo/touch/AI bleed.

No gaps identified. Plan is ready.

---

## Execution

After this plan is saved and committed, the next step is to invoke one of:

- **superpowers:subagent-driven-development** (recommended for this plan — many small TDD tasks benefit from fresh subagent per task)
- **superpowers:executing-plans** (inline batch execution)
