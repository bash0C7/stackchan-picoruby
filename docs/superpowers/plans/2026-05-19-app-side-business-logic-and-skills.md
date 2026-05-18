# App-side Business Logic Migration + Deploy Skills Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move `Face` DSL + `Dispatcher` from the `picoruby-stackchan-protocol` mrbgem into the autostart application script, leave only `FrameParser` in firmware, forbid the on-device `.rb` compile path, and standardize all device interactions via project-local `stackchan-device-*` skills.

**Spec:** `docs/superpowers/specs/2026-05-19-app-side-business-logic-and-skills.md`

**Architecture:** Inline `Face` (~160 lines) and `Dispatcher` (~74 lines) into `mrbgems/picoruby-stackchan-protocol/examples/application.rb` under a new `StackchanApp` namespace. Firmware retains only `StackchanProtocol::FrameParser`. New `lib/ruby_class_extract.rb` uses prism AST to load only class/module definitions from the application script into host CRuby tests (production code and test target share one file). Rakefile gets `upload_mrb` (DST required) and `upload_appmrb` (DST hard-coded), `upload` deleted. 15 `stackchan-device-*` skills standardize device operations; 11 get slash command aliases.

**Tech Stack:** PicoRuby (R2P2-ESP32 target, BTstack BLE), Ruby (CRuby for host tests via Bundler + test-unit), prism (AST parser), Rake (orchestration), `.claude/skills/` + `.claude/commands/` (project automation).

---

## Scope

This plan covers spec Migration Order steps 1-14 in full. Phase A HITL re-entry (steps 13-14 of spec) is part of this plan, executed at the end after the new device path is live.

---

## Part 1: Host migration (Tasks 1-8, no device required)

## Task 1: Implement `lib/ruby_class_extract.rb` library (TDD)

**Files:**
- Create: `Gemfile`
- Create: `Rakefile` (project root, additional `task :test`)
- Create: `lib/ruby_class_extract.rb`
- Create: `lib/ruby_class_extract/version.rb`
- Create: `lib/ruby_class_extract/README.md`
- Create: `test/ruby_class_extract_test.rb`

- [ ] **Step 1.1: Add project-root Gemfile**

Create `Gemfile`:

```ruby
source 'https://rubygems.org'

gem 'prism', '~> 0.30'
gem 'test-unit', '~> 3.6'
gem 'rake', '~> 13.0'
```

Run `bundle install`. Expected: Gemfile.lock generated, no errors.

- [ ] **Step 1.2: Add project-root Rakefile `task :test`**

The root Rakefile already exists for `r2p2:*` tasks. Add at the top (after existing `require`s):

```ruby
require 'rake/testtask'

Rake::TestTask.new(:test) do |t|
  t.libs << 'lib'
  t.libs << 'test'
  t.test_files = FileList['test/**/*_test.rb']
  t.warning = false
end
```

Run `bundle exec rake -T | grep test`. Expected: `rake test` listed.

- [ ] **Step 1.3: Write failing test for basic class extraction**

Create `test/ruby_class_extract_test.rb`:

```ruby
$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'test/unit'
require 'tempfile'
require 'ruby_class_extract'

class RubyClassExtractTest < Test::Unit::TestCase
  def setup
    @fixture = Tempfile.new(['fixture', '.rb'])
    @fixture.write(<<~RUBY)
      require 'nonexistent_gem'
      puts "top-level execution should be stripped"

      module Sample
        class Greeter
          def hello
            "hi"
          end
        end
      end

      Sample::Greeter.new.hello
    RUBY
    @fixture.close
  end

  def teardown
    @fixture.unlink
  end

  def test_load_classes_from_strips_requires_and_top_level
    RubyClassExtract.load_classes_from(@fixture.path)
    assert defined?(Sample::Greeter), "class should be loaded"
    assert_equal "hi", Sample::Greeter.new.hello
  end
end
```

- [ ] **Step 1.4: Run test, confirm failure**

Run: `bundle exec rake test TESTOPTS="--name=/test_load_classes_from_strips_requires/"`
Expected: `LoadError: cannot load such file -- ruby_class_extract`

- [ ] **Step 1.5: Implement minimal `RubyClassExtract`**

Create `lib/ruby_class_extract/version.rb`:

```ruby
module RubyClassExtract
  VERSION = '0.1.0'
end
```

Create `lib/ruby_class_extract.rb`:

```ruby
require 'prism'
require 'tempfile'
require_relative 'ruby_class_extract/version'

module RubyClassExtract
  module_function

  def load_classes_from(path, exclude_superclasses: [])
    source = File.read(path)
    result = Prism.parse(source)
    raise "parse error: #{result.errors}" unless result.success?

    extracted = collect_class_module_source(result.value, exclude_superclasses)
    tmpfile = Tempfile.new(['ruby_class_extract', '.rb'])
    tmpfile.write(extracted.join("\n"))
    tmpfile.close
    load tmpfile.path
    # Tempfile finalizer cleans the file at GC / process exit.
    nil
  end

  def collect_class_module_source(node, exclude_superclasses)
    out = []
    walk(node, exclude_superclasses, out)
    out
  end

  def walk(node, exclude_superclasses, out)
    return unless node.respond_to?(:child_nodes)

    case node
    when Prism::ClassNode
      sup = node.superclass
      sup_name = sup.respond_to?(:slice) ? sup.slice : nil
      return if sup_name && exclude_superclasses.include?(sup_name)
      out << node.slice
    when Prism::ModuleNode
      # Recurse into modules; emit only nested classes/modules selectively.
      # Simplest correct approach: emit the module slice verbatim (which
      # naturally includes its nested class defs).
      out << node.slice
    else
      node.child_nodes.compact.each do |child|
        walk(child, exclude_superclasses, out)
      end
    end
  end
end
```

- [ ] **Step 1.6: Run test, confirm PASS**

Run: `bundle exec rake test TESTOPTS="--name=/test_load_classes_from_strips_requires/"`
Expected: 1 test, 1 PASS, 0 fail.

- [ ] **Step 1.7: Add failing test for `exclude_superclasses`**

Append to `test/ruby_class_extract_test.rb` (inside `RubyClassExtractTest`):

```ruby
  def test_exclude_superclasses_skips_matching_class
    fix = Tempfile.new(['fixture', '.rb'])
    fix.write(<<~RUBY)
      class BLE
      end

      class StackChanApp < BLE
        def boot; end
      end

      class Plain
        def whatever; end
      end
    RUBY
    fix.close

    # Pre-define BLE so the test does not actually inherit from a real BLE.
    Object.const_set(:BLE, Class.new) unless defined?(BLE)

    RubyClassExtract.load_classes_from(fix.path, exclude_superclasses: %w[BLE])
    assert defined?(Plain), "non-excluded class should be loaded"
    refute defined?(StackChanApp), "BLE-derived class should be skipped"
    fix.unlink
  end
```

- [ ] **Step 1.8: Run test, confirm failure**

Run: `bundle exec rake test TESTOPTS="--name=/test_exclude_superclasses/"`
Expected: FAIL — `StackChanApp` IS defined (current implementation does not honor the exclusion for top-level classes).

Note: the current Step 1.5 walk does check `exclude_superclasses` for top-level `ClassNode`s — verify whether it actually triggers; the `BLE` constant name match may not equal the slice format (`BLE` vs `BLE` should match, but check).

- [ ] **Step 1.9: Fix exclusion logic if needed**

If the test in 1.8 already passes, skip this step and move to 1.10. If it fails because the slice form is `BLE` but matched against a different format, normalize the comparison. Replace the `sup_name` line in `lib/ruby_class_extract.rb`:

```ruby
      sup_name = sup.respond_to?(:slice) ? sup.slice.strip : nil
```

Re-run the test. Expected: PASS.

- [ ] **Step 1.10: Add test for tempfile lifecycle**

Append:

```ruby
  def test_tempfile_is_writable_at_load_time
    fix = Tempfile.new(['fixture', '.rb'])
    fix.write("class Beacon\nend\n")
    fix.close
    RubyClassExtract.load_classes_from(fix.path)
    assert defined?(Beacon), "class loaded from tempfile-extracted source"
    fix.unlink
  end
```

Run: `bundle exec rake test TESTOPTS="--name=/test_tempfile/"`
Expected: 1 PASS.

- [ ] **Step 1.11: Write library README**

Create `lib/ruby_class_extract/README.md`:

```markdown
# ruby_class_extract

## Why this exists

PicoRuby (R2P2-ESP32) and other on-device Ruby runtimes ship `require`able
gems that are not available in host CRuby (e.g. `spi`, `gpio`, `ble`,
`ili9342`). A production script that does `require 'ble'` at the top cannot
be `load`ed by a CRuby test process. Yet the script also defines pure-Ruby
classes (DSLs, dispatchers, geometry) whose behavior we want to assert in
fast host tests.

## How it works

1. `Prism.parse(File.read(path))` produces an AST.
2. We walk the AST collecting `ClassNode` and `ModuleNode` definitions.
3. Classes whose superclass name appears in `exclude_superclasses:` are
   skipped (they reference on-device-only APIs).
4. The collected nodes are emitted as Ruby source into a Tempfile.
5. `Kernel#load` evaluates the tempfile. Tempfile lifecycle is managed by
   Ruby's `Tempfile` finalizer.

## Why this is black magic

The production script and the test target are the *same file*. We parse the
production source, re-synthesize a subset of it as a synthetic Ruby script,
and load that subset into the test process. This is not standard testing
practice; normal patterns either share library code via `require` or run
end-to-end on the real runtime. We use this technique because the script
is a single deployable artifact (`/home/app.mrb` for autostart) that mixes
hardware bootstrap with pure-Ruby class definitions.

## Usage

```ruby
require 'ruby_class_extract'

RubyClassExtract.load_classes_from(
  'mrbgems/picoruby-stackchan-protocol/examples/application.rb',
  exclude_superclasses: %w[BLE],
)
# Subsequent code can reference loaded classes:
display = FakeDisplay.new
StackchanApp::Face::Sad.new.draw(display)
```
```

- [ ] **Step 1.12: Run full test suite**

Run: `bundle exec rake test`
Expected: 3 tests, 3 PASS.

- [ ] **Step 1.13: Commit**

```bash
git add Gemfile Gemfile.lock Rakefile lib/ruby_class_extract.rb \
        lib/ruby_class_extract/version.rb lib/ruby_class_extract/README.md \
        test/ruby_class_extract_test.rb
git commit -m "$(cat <<'EOF'
feat(lib): add ruby_class_extract for host-testing on-device Ruby scripts

Prism-based AST extraction loads only class/module definitions from a
script with on-device-only requires, enabling host CRuby tests against the
production deployable artifact (e.g. /home/app.mrb autostart payload).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Project test scaffold + fake helpers

**Files:**
- Create: `test/test_helper.rb`
- Create: `test/fake_display.rb` (copy from mrbgem)
- Create: `test/fake_led.rb`

- [ ] **Step 2.1: Inspect existing FakeDisplay**

Run: `cat /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/mrbgems/picoruby-stackchan-protocol/test/fake_display.rb`
Note its API: `calls` array of `[:method_name, [args...]]` entries.

- [ ] **Step 2.2: Copy FakeDisplay to project root**

Run:
```bash
cp /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/mrbgems/picoruby-stackchan-protocol/test/fake_display.rb \
   /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/test/fake_display.rb
```

- [ ] **Step 2.3: Create FakeLED**

`StackchanApp::Dispatcher` (after migration) will call `led.animate_side(side, color, mode)` and `led.tick(time_ms)` and possibly `led.show`. Create `test/fake_led.rb`:

```ruby
class FakeLed
  attr_reader :calls

  def initialize
    @calls = []
  end

  def animate_side(side, color, mode)
    @calls << [:animate_side, [side, color, mode]]
  end

  def tick(time_ms)
    @calls << [:tick, [time_ms]]
  end

  def show
    @calls << [:show, []]
  end

  def brightness=(v)
    @calls << [:brightness=, [v]]
  end
end
```

- [ ] **Step 2.4: Create test_helper.rb**

Create `test/test_helper.rb`:

```ruby
$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
$LOAD_PATH.unshift(File.expand_path('.', __dir__))

require 'test/unit'
require 'ruby_class_extract'
require 'fake_display'
require 'fake_led'

APPLICATION_RB = File.expand_path(
  '../mrbgems/picoruby-stackchan-protocol/examples/application.rb', __dir__
)

# Pre-declare on-device-only base classes so RubyClassExtract can compare
# against them without actually loading BLE etc.
Object.const_set(:BLE, Class.new) unless defined?(BLE)

# Pre-define ILI9342::Color and other on-device constants referenced by Face
# class bodies. Application code references these as bare constants inside
# class definitions, so they must resolve at load time.
unless defined?(ILI9342)
  module ILI9342
    module Color
      WHITE = 0xFFFF
    end
  end
end

# Load all class/module definitions from application.rb that are not
# BLE-derived (StackChanApp itself uses on-device BLE API and is skipped).
RubyClassExtract.load_classes_from(APPLICATION_RB, exclude_superclasses: %w[BLE])
```

Note: `ILI9342::Color::WHITE` etc. are referenced by `Face::Base` constants. At AST load time the constant must resolve. The constants do not need real RGB565 values for tests; placeholder integers suffice.

- [ ] **Step 2.5: Smoke-test the loader against a tiny fixture**

For now, application.rb does not yet contain `StackchanApp::Face`. Create a temporary placeholder so the smoke test passes:

Append to `test/test_helper.rb` (temporary, removed once application.rb has real `StackchanApp::Face`):

```ruby
# Placeholder until Task 3 inlines StackchanApp into application.rb.
unless defined?(StackchanApp::Face)
  module StackchanApp
    module Face
      class Placeholder; end
    end
  end
end
```

- [ ] **Step 2.6: Commit**

```bash
git add test/test_helper.rb test/fake_display.rb test/fake_led.rb
git commit -m "$(cat <<'EOF'
test: add host test scaffold (test_helper, FakeDisplay, FakeLed)

test_helper loads class/module definitions from application.rb via
RubyClassExtract so host tests run against the production deployable.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Inline `Face` module into application.rb under `StackchanApp` namespace (TDD)

**Files:**
- Modify: `mrbgems/picoruby-stackchan-protocol/examples/application.rb` (insert Face module + namespace rename)
- Create: `test/face_test.rb`

- [ ] **Step 3.1: Write the failing face geometry tests**

Create `test/face_test.rb`:

```ruby
$LOAD_PATH.unshift(File.expand_path('.', __dir__))
require 'test_helper'

class FaceNeutralTest < Test::Unit::TestCase
  def setup; @display = FakeDisplay.new; end

  def test_neutral_draw_sequence
    StackchanApp::Face::Neutral.new.draw(@display)
    methods = @display.calls.map(&:first)
    assert_equal [:fill, :draw_ellipse, :draw_ellipse, :draw_line, :draw_line], methods
  end
end

class FaceSadTest < Test::Unit::TestCase
  def setup; @display = FakeDisplay.new; end

  def test_sad_delta_y_is_negative_eight
    assert_equal(-8, StackchanApp::Face::Sad::DELTA_Y)
  end

  def test_sad_corners_droop_below_center
    StackchanApp::Face::Sad.new.draw_mouth(@display)
    assert_equal [135, 148, 160, 140, ILI9342::Color::WHITE], @display.calls[0].last
    assert_equal [160, 140, 185, 148, ILI9342::Color::WHITE], @display.calls[1].last
  end
end

class FaceAngryTest < Test::Unit::TestCase
  def setup; @display = FakeDisplay.new; end

  def test_brow_constants
    assert_equal 18, StackchanApp::Face::BROW_OFFSET_Y
    assert_equal 16, StackchanApp::Face::BROW_HALF_LENGTH
    assert_equal 8,  StackchanApp::Face::BROW_INNER_DROP
  end

  def test_angry_draw_sequence
    StackchanApp::Face::Angry.new.draw(@display)
    methods = @display.calls.map(&:first)
    assert_equal [:fill, :draw_ellipse, :draw_ellipse, :draw_line, :draw_line, :draw_line, :draw_line], methods
  end
end
```

- [ ] **Step 3.2: Run, confirm failure**

Run: `bundle exec rake test TESTOPTS="--name=/Face/"`
Expected: FAIL — `NameError: uninitialized constant StackchanApp::Face::Neutral`.

- [ ] **Step 3.3: Inline Face module into application.rb**

In `mrbgems/picoruby-stackchan-protocol/examples/application.rb`, find the section header `# [2] cold-boot init` (around line 27). Insert AFTER all the require statements and BEFORE the cold-boot init (i.e., between line ~24 and line ~27):

```ruby
# ================================
# === StackchanApp::Face module ==
# ================================
module StackchanApp
  module Face
    EYE_LEFT_CX  = 110
    EYE_RIGHT_CX = 210
    EYE_LEFT_CY  = 100
    EYE_RIGHT_CY = 100
    EYE_RADIUS   = 18
    EYE_COLOR    = ILI9342::Color::WHITE

    MOUTH_CX     = 160
    MOUTH_CY     = 140
    MOUTH_HALF_WIDTH = 25

    SURPRISED_MOUTH_HALF_W = 6
    SURPRISED_MOUTH_HALF_H = 12

    BROW_OFFSET_Y    = 18
    BROW_HALF_LENGTH = 16
    BROW_INNER_DROP  = 8

    class Base
      DELTA_Y = 0

      def draw(display)
        display.fill(0x0000)
        draw_eyes(display)
        draw_mouth(display)
      end

      def draw_eyes(display)
        display.draw_ellipse(EYE_LEFT_CX,  EYE_LEFT_CY,  EYE_RADIUS, EYE_RADIUS, EYE_COLOR, fill: true)
        display.draw_ellipse(EYE_RIGHT_CX, EYE_RIGHT_CY, EYE_RADIUS, EYE_RADIUS, EYE_COLOR, fill: true)
      end

      def draw_mouth(display)
        corner_y = MOUTH_CY - self.class::DELTA_Y
        display.draw_line(MOUTH_CX - MOUTH_HALF_WIDTH, corner_y,
                          MOUTH_CX,                    MOUTH_CY, EYE_COLOR)
        display.draw_line(MOUTH_CX,                    MOUTH_CY,
                          MOUTH_CX + MOUTH_HALF_WIDTH, corner_y, EYE_COLOR)
      end

      def redraw_eyes_open(display)
        draw_eyes(display)
      end
    end

    class Neutral < Base
      DELTA_Y = 0
    end

    class Smile < Base
      DELTA_Y = 8
    end

    class Joy < Base
      DELTA_Y = 18
    end

    class Sad < Base
      DELTA_Y = -8
    end

    class Angry < Base
      DELTA_Y = 0

      def draw(display)
        super
        display.draw_line(
          EYE_LEFT_CX - BROW_HALF_LENGTH, EYE_LEFT_CY - BROW_OFFSET_Y,
          EYE_LEFT_CX + BROW_HALF_LENGTH, EYE_LEFT_CY - BROW_OFFSET_Y + BROW_INNER_DROP,
          EYE_COLOR
        )
        display.draw_line(
          EYE_RIGHT_CX - BROW_HALF_LENGTH, EYE_RIGHT_CY - BROW_OFFSET_Y + BROW_INNER_DROP,
          EYE_RIGHT_CX + BROW_HALF_LENGTH, EYE_RIGHT_CY - BROW_OFFSET_Y,
          EYE_COLOR
        )
      end
    end

    class Surprised < Base
      def draw_mouth(display)
        display.draw_rect(MOUTH_CX - SURPRISED_MOUTH_HALF_W, MOUTH_CY - SURPRISED_MOUTH_HALF_H,
                          SURPRISED_MOUTH_HALF_W * 2, SURPRISED_MOUTH_HALF_H * 2, EYE_COLOR, fill: true)
      end
    end

    class Closed < Base
      def draw_eyes(display)
        display.draw_line(EYE_LEFT_CX  - EYE_RADIUS, EYE_LEFT_CY,
                          EYE_LEFT_CX  + EYE_RADIUS, EYE_LEFT_CY,  EYE_COLOR)
        display.draw_line(EYE_RIGHT_CX - EYE_RADIUS, EYE_RIGHT_CY,
                          EYE_RIGHT_CX + EYE_RADIUS, EYE_RIGHT_CY, EYE_COLOR)
      end
    end
  end
end
```

Then change the cold-boot Face::Neutral.draw call (search for `StackchanProtocol::Face::Neutral.new.draw(display)`, replace with `StackchanApp::Face::Neutral.new.draw(display)`).

Search for `StackchanProtocol::Face::Closed.new.draw(@display)` in `heartbeat_callback`, replace with `StackchanApp::Face::Closed.new.draw(@display)`.

- [ ] **Step 3.4: Remove the test_helper placeholder**

In `test/test_helper.rb`, delete the temporary placeholder block (lines starting `# Placeholder until Task 3` through `end`).

- [ ] **Step 3.5: Run face tests, confirm PASS**

Run: `bundle exec rake test TESTOPTS="--name=/Face/"`
Expected: 7 tests (FaceNeutralTest: 1, FaceSadTest: 2, FaceAngryTest: 2 + Surprised/Smile/Joy/Closed each at least 1 baseline if you add them later). Initial PASS: 5 PASSes for the 3 test classes above.

If a test fails because a `Face::Base` method or constant is referenced from inside a class body and prism's `slice` includes the outer scope incorrectly, debug by printing the tempfile content from `RubyClassExtract.load_classes_from` (add a `puts File.read(tmpfile.path)` line, then revert).

- [ ] **Step 3.6: Commit**

```bash
git add mrbgems/picoruby-stackchan-protocol/examples/application.rb \
        test/face_test.rb test/test_helper.rb
git commit -m "$(cat <<'EOF'
feat(app): inline StackchanApp::Face module into application.rb

Face DSL moves from picoruby-stackchan-protocol mrbgem (firmware) to the
autostart script (application). Cold-boot and blink Face::Neutral / Closed
draws updated to the StackchanApp namespace.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Inline `Dispatcher` class into application.rb (TDD)

**Files:**
- Modify: `mrbgems/picoruby-stackchan-protocol/examples/application.rb`
- Create: `test/dispatcher_test.rb`

- [ ] **Step 4.1: Write the failing dispatcher tests**

Create `test/dispatcher_test.rb`:

```ruby
$LOAD_PATH.unshift(File.expand_path('.', __dir__))
require 'test_helper'

class DispatcherFaceTest < Test::Unit::TestCase
  def setup
    @display = FakeDisplay.new
    @led     = FakeLed.new
    @stdout  = MiniSink.new
    @disp    = StackchanApp::Dispatcher.new(display: @display, led: @led, stdout: @stdout)
  end

  class MiniSink
    attr_reader :writes
    def initialize; @writes = []; end
    def write(b); @writes << b; end
  end

  def test_F_0_draws_neutral
    @disp.handle({ "F" => "0" })
    assert @display.calls.any? { |c| c.first == :draw_ellipse }
  end

  def test_F_4_draws_sad
    @disp.handle({ "F" => "4" })
    line = @display.calls.find { |c| c.first == :draw_line }.last
    assert_equal 148, line[1]
  end

  def test_F_5_draws_angry_with_brows
    @disp.handle({ "F" => "5" })
    methods = @display.calls.map(&:first)
    assert_equal [:fill, :draw_ellipse, :draw_ellipse, :draw_line, :draw_line, :draw_line, :draw_line], methods
  end

  def test_F_known_writes_ack_dot
    @disp.handle({ "F" => "0" })
    assert_equal [".", "."], @stdout.writes.first(2).select { |w| w == "." } | ["."]
    # At minimum, exactly one "." byte was written for the F frame.
    assert_includes @stdout.writes, "."
  end

  def test_F_unknown_writes_question_mark
    @disp.handle({ "F" => "99" })
    assert_includes @stdout.writes, "?"
  end
end
```

- [ ] **Step 4.2: Run, confirm failure**

Run: `bundle exec rake test TESTOPTS="--name=/Dispatcher/"`
Expected: FAIL — `NameError: uninitialized constant StackchanApp::Dispatcher`.

- [ ] **Step 4.3: Inline Dispatcher into application.rb**

Read the current mrbgem dispatcher:

```bash
cat /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/mrbgems/picoruby-stackchan-protocol/mrblib/stackchan_protocol/dispatcher.rb
```

Insert the Dispatcher into `application.rb` AFTER the Face module section (right after the `end` that closes `module StackchanApp`):

```ruby
# ====================================
# === StackchanApp::Dispatcher class ==
# ====================================
module StackchanApp
  class Dispatcher
    OK_BYTE    = "."
    ERROR_BYTE = "?"

    FACE_TABLE = {
      "0" => Face::Neutral,
      "1" => Face::Smile,
      "2" => Face::Joy,
      "3" => Face::Surprised,
      "4" => Face::Sad,
      "5" => Face::Angry,
    }.freeze

    MODE_TABLE = {
      "s" => :solid,
      "b" => :breathing,
      "k" => :blink,
    }.freeze

    SIDE_TABLE = {
      "L" => :left,
      "R" => :right,
      "B" => :both,
    }.freeze

    attr_reader :current_face_class

    def initialize(display:, led:, stdout:)
      @display = display
      @led     = led
      @stdout  = stdout
      @current_face_class = Face::Neutral
    end

    def handle(frame)
      if frame.key?("F")
        face_class = FACE_TABLE[frame["F"]]
        if face_class
          face_class.new.draw(@display)
          @current_face_class = face_class
          @stdout.write(OK_BYTE)
        else
          @stdout.write(ERROR_BYTE)
        end
      end

      if frame.key?("S")
        side  = SIDE_TABLE[frame["S"]]
        color = frame["C"]
        mode  = MODE_TABLE[frame["M"]]
        if side && color && mode
          @led.animate_side(side, color, mode)
          @stdout.write(OK_BYTE)
        else
          @stdout.write(ERROR_BYTE)
        end
      end
    end
  end
end
```

Then update the BLE peripheral's dispatcher creation. Find:
```ruby
@dispatcher = StackchanProtocol::Dispatcher.new(
  display: @display, led: @led, stdout: self
)
```
Replace with:
```ruby
@dispatcher = StackchanApp::Dispatcher.new(
  display: @display, led: @led, stdout: self
)
```

Note: the actual MODE_TABLE / SIDE_TABLE / handle logic comes from the existing mrbgem `dispatcher.rb`. The snippet above is a starting point; copy the exact handle method body from the mrbgem source (run `cat` again to confirm details).

- [ ] **Step 4.4: Run dispatcher tests, confirm PASS**

Run: `bundle exec rake test TESTOPTS="--name=/Dispatcher/"`
Expected: 5 PASSes.

If the LED-related test logic differs because the mrbgem's MODE_TABLE keys differ, adjust the test or the inlined table to match. Source of truth is the existing `dispatcher.rb` in the mrbgem; copy verbatim.

- [ ] **Step 4.5: Commit**

```bash
git add mrbgems/picoruby-stackchan-protocol/examples/application.rb \
        test/dispatcher_test.rb
git commit -m "$(cat <<'EOF'
feat(app): inline StackchanApp::Dispatcher into application.rb

Dispatcher class with FACE_TABLE / MODE_TABLE / SIDE_TABLE moves from
picoruby-stackchan-protocol mrbgem to the autostart script. AckSink
contract (write byte) unchanged.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Migrate golden SHA test infrastructure + 4 existing goldens

**Files:**
- Create: `test/face_golden_test.rb` (copy + adapt from mrbgem)
- Create: `spec/golden/face_neutral.sha256` (copy from mrbgem)
- Create: `spec/golden/face_smile.sha256` (copy)
- Create: `spec/golden/face_joy.sha256` (copy)
- Create: `spec/golden/face_surprised.sha256` (copy)

- [ ] **Step 5.1: Copy 4 existing goldens to project root**

```bash
mkdir -p spec/golden
cp mrbgems/picoruby-stackchan-protocol/spec/golden/face_neutral.sha256 spec/golden/
cp mrbgems/picoruby-stackchan-protocol/spec/golden/face_smile.sha256   spec/golden/
cp mrbgems/picoruby-stackchan-protocol/spec/golden/face_joy.sha256     spec/golden/
cp mrbgems/picoruby-stackchan-protocol/spec/golden/face_surprised.sha256 spec/golden/
```

- [ ] **Step 5.2: Adapt face_golden_test.rb (copy + namespace + path)**

Inspect the mrbgem version:
```bash
cat /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/mrbgems/picoruby-stackchan-protocol/test/face_golden_test.rb
cat /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/mrbgems/picoruby-stackchan-protocol/test/face_golden_hash.rb
```

Create `test/face_golden_test.rb` (preserving the canonical_dump byte-for-byte so existing SHAs match):

```ruby
$LOAD_PATH.unshift(File.expand_path('.', __dir__))
require 'test_helper'
require 'digest'

class FaceGoldenTest < Test::Unit::TestCase
  GOLDEN_DIR = File.expand_path('../spec/golden', __dir__)

  FACE_CASES = {
    neutral:   StackchanApp::Face::Neutral,
    smile:     StackchanApp::Face::Smile,
    joy:       StackchanApp::Face::Joy,
    surprised: StackchanApp::Face::Surprised,
    sad:       StackchanApp::Face::Sad,
    angry:     StackchanApp::Face::Angry,
  }.freeze

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

- [ ] **Step 5.3: Run golden test**

Run: `bundle exec rake test TESTOPTS="--name=/FaceGolden/"`
Expected: 6 tests. 4 PASSes (neutral/smile/joy/surprised match copied goldens). 2 OMITs (sad/angry — goldens not yet copied since Phase A HITL pending).

If any of the 4 existing goldens FAIL with SHA mismatch, the canonical_dump serialization drifted between mrbgem and project root. Verify by printing actual vs expected SHA, then either:
  - Adjust canonical_dump to match (preserve the original behavior), OR
  - Re-register goldens (only valid if visual approval done — for the 4 existing faces, prior phases already approved).

Choose the first option (preserve byte-for-byte).

- [ ] **Step 5.4: Commit**

```bash
git add test/face_golden_test.rb \
        spec/golden/face_neutral.sha256 spec/golden/face_smile.sha256 \
        spec/golden/face_joy.sha256 spec/golden/face_surprised.sha256
git commit -m "$(cat <<'EOF'
test(face): migrate golden-SHA regression infra to project root

Same canonical_dump format as the mrbgem original, so the 4 existing
goldens (neutral/smile/joy/surprised) match without re-registration.
Sad/angry remain OMITted until Phase A HITL.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Migrate `face:register_golden` rake task to root Rakefile

**Files:**
- Modify: `Rakefile` (project root)

- [ ] **Step 6.1: Add face:register_golden task**

Append to the root `Rakefile` (after the existing namespaces):

```ruby
namespace :face do
  desc 'compute SHA256 of StackchanApp::Face::<NAME> draw call sequence and write spec/golden/face_<NAME>.sha256'
  task :register_golden do
    name = ENV.fetch('FACE') { abort 'FACE=<name> required' }
    $LOAD_PATH.unshift(File.expand_path('lib', __dir__))
    $LOAD_PATH.unshift(File.expand_path('test', __dir__))
    require 'test_helper'
    require 'face_golden_test'   # provides FaceGoldenTest.compute_sha / FACE_CASES

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

Note: requiring `test_helper` from a rake task triggers `RubyClassExtract.load_classes_from` once. This is harmless (single load, idempotent). `require 'face_golden_test'` will load the Test::Unit class but at_exit autorun is only registered when the test runner is the entry point; from rake task context it is just a class loaded into memory.

If at_exit autorun does fire from the rake task (test/unit may register an at_exit hook on `require`), refactor: extract `FACE_CASES` and `compute_sha` from `FaceGoldenTest` into a plain `FaceGoldenHash` module in `test/face_golden_hash.rb`, and have `face_golden_test.rb` `require 'face_golden_hash'` + delegate. Verify by running the task and checking for unwanted test output.

- [ ] **Step 6.2: Test the task end-to-end for neutral**

Run:
```bash
bundle exec rake face:register_golden FACE=neutral
```

Expected output: `[face:register_golden] wrote .../spec/golden/face_neutral.sha256 sha=<64-hex>`

Verify the SHA matches the file already committed in Task 5:
```bash
diff spec/golden/face_neutral.sha256 <(echo "$(cat spec/golden/face_neutral.sha256)")
```

(Trivially equal — the task just rewrote the same value.)

- [ ] **Step 6.3: Re-run FaceGoldenTest, confirm 4 PASS + 2 OMIT**

Run: `bundle exec rake test TESTOPTS="--name=/FaceGolden/"`
Expected: 6 tests, 4 PASS, 2 OMIT, 0 FAIL.

- [ ] **Step 6.4: Commit**

```bash
git add Rakefile
git commit -m "$(cat <<'EOF'
feat(rake): migrate face:register_golden to root Rakefile

Targets new StackchanApp::Face::* under the inlined application.rb. Same
canonical_dump format as the mrbgem original, so the task is a drop-in
replacement for HITL golden registration.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Shrink the mrbgem (delete Face / Dispatcher / golden code + tests)

**Files:**
- Modify: `mrbgems/picoruby-stackchan-protocol/mrblib/stackchan_protocol.rb` (delete Face module, keep FrameParser wrapper)
- Delete: `mrbgems/picoruby-stackchan-protocol/mrblib/stackchan_protocol/dispatcher.rb`
- Delete: `mrbgems/picoruby-stackchan-protocol/test/stackchan_protocol_test.rb`
- Delete: `mrbgems/picoruby-stackchan-protocol/test/dispatcher_test.rb`
- Delete: `mrbgems/picoruby-stackchan-protocol/test/face_golden_test.rb`
- Delete: `mrbgems/picoruby-stackchan-protocol/test/face_golden_hash.rb`
- Delete: `mrbgems/picoruby-stackchan-protocol/spec/golden/` (entire dir + `.keep`)
- Modify: `mrbgems/picoruby-stackchan-protocol/Rakefile` (delete face:register_golden task)
- Create: `mrbgems/picoruby-stackchan-protocol/test/frame_parser_test.rb` (if not already present)

- [ ] **Step 7.1: Delete Face module from stackchan_protocol.rb**

Replace the entire contents of `mrbgems/picoruby-stackchan-protocol/mrblib/stackchan_protocol.rb` with:

```ruby
require 'stackchan-protocol/frame_parser'

module StackchanProtocol
  # FrameParser is the only public class — see frame_parser.rb.
end
```

- [ ] **Step 7.2: Delete dispatcher source + tests**

```bash
rm mrbgems/picoruby-stackchan-protocol/mrblib/stackchan_protocol/dispatcher.rb
rm mrbgems/picoruby-stackchan-protocol/test/dispatcher_test.rb
rm mrbgems/picoruby-stackchan-protocol/test/stackchan_protocol_test.rb
rm mrbgems/picoruby-stackchan-protocol/test/face_golden_test.rb
rm -f mrbgems/picoruby-stackchan-protocol/test/face_golden_hash.rb
rm -rf mrbgems/picoruby-stackchan-protocol/spec/golden
```

- [ ] **Step 7.3: Verify or create a frame_parser_test.rb**

Check whether one exists:
```bash
ls mrbgems/picoruby-stackchan-protocol/test/
```

If `frame_parser_test.rb` is missing, create:

```ruby
require_relative 'test_helper'

class FrameParserTest < Test::Unit::TestCase
  def setup; @parser = StackchanProtocol::FrameParser.new; end

  def test_decodes_single_frame
    frames = @parser.feed("<F:4>")
    assert_equal [{ "F" => "4" }], frames
  end

  def test_buffers_across_chunks
    @parser.feed("<F:")
    frames = @parser.feed("4>")
    assert_equal [{ "F" => "4" }], frames
  end

  def test_handles_multiple_kv
    frames = @parser.feed("<F:1,S:L>")
    assert_equal [{ "F" => "1", "S" => "L" }], frames
  end

  def test_increments_parse_error_count_on_empty_body
    @parser.feed("<>")
    assert_equal 1, @parser.parse_error_count
  end
end
```

- [ ] **Step 7.4: Delete face:register_golden from mrbgem Rakefile**

Inspect:
```bash
cat mrbgems/picoruby-stackchan-protocol/Rakefile
```

Remove the `namespace :face do ... end` block.

- [ ] **Step 7.5: Run mrbgem-local tests**

Run:
```bash
cd mrbgems/picoruby-stackchan-protocol
bundle exec rake test
```

Expected: only FrameParser tests run, all PASS.

- [ ] **Step 7.6: Run project-root tests, confirm no regression**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby
bundle exec rake test
```

Expected: all project-root tests PASS or OMIT (sad/angry goldens still OMIT until HITL).

- [ ] **Step 7.7: Commit**

```bash
git add mrbgems/picoruby-stackchan-protocol/mrblib/stackchan_protocol.rb \
        mrbgems/picoruby-stackchan-protocol/Rakefile \
        mrbgems/picoruby-stackchan-protocol/test/frame_parser_test.rb
git add -u  # capture deletions
git commit -m "$(cat <<'EOF'
refactor(mrbgem): shrink to FrameParser only

Face module, Dispatcher class, all related tests, goldens, and the
face:register_golden rake task move out of the firmware mrbgem and into
the project root (application-side). Only FrameParser (48 lines, pure
Ruby, stable framework piece) remains in firmware.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Root Rakefile changes (upload paths + face_verify + ble_control_smoke callsite)

**Files:**
- Modify: `Rakefile` (project root)

- [ ] **Step 8.1: Add upload_mrb_via_picomodem helper**

In `Rakefile`, before `namespace :r2p2 do`, add:

```ruby
def upload_mrb_via_picomodem(src:, dst:, port:)
  picorbc = "#{R2P2_ROOT}/components/picoruby-esp32/picoruby/bin/picorbc"
  abort "picorbc not found at #{picorbc} — run `rake r2p2:setup` first" unless File.executable?(picorbc)
  build_dir = File.expand_path('tmp/build', __dir__)
  mkdir_p build_dir
  base = File.basename(src, File.extname(src))
  mrb_path = File.join(build_dir, "#{base}.mrb")
  rm_f mrb_path
  sh picorbc, '-o', mrb_path, src
  abort "picorbc produced no output at #{mrb_path}" unless File.exist?(mrb_path)
  puts "[upload_mrb] compiled #{src} -> #{mrb_path} (#{File.size(mrb_path)} bytes)"
  Deploy::Picomodem.upload(src: mrb_path, dst: dst, port: port)
end
```

- [ ] **Step 8.2: Delete `:upload` task, replace `:upload_mrb` body, add `:upload_appmrb`**

In `namespace :r2p2 do`, find the existing `task :upload do ... end` block and DELETE it entirely.

Replace the existing `task :upload_mrb do ... end` body with:

```ruby
  desc 'host-compile SRC=path/to/foo.rb to .mrb and upload to DST=/home/path/foo.mrb'
  task :upload_mrb do
    src = ENV.fetch('SRC') { abort 'SRC=path/to/foo.rb required for r2p2:upload_mrb' }
    dst = ENV.fetch('DST') { abort 'DST=/home/...mrb required for r2p2:upload_mrb' }
    src_path = File.expand_path(src, __dir__)
    abort "SRC not found: #{src_path}" unless File.exist?(src_path)
    upload_mrb_via_picomodem(src: src_path, dst: dst, port: espport)
  end
```

Add immediately after:

```ruby
  desc 'host-compile SRC=path/to/app.rb and upload as autostart payload /home/app.mrb'
  task :upload_appmrb do
    src = ENV.fetch('SRC') { abort 'SRC=path required for r2p2:upload_appmrb' }
    src_path = File.expand_path(src, __dir__)
    abort "SRC not found: #{src_path}" unless File.exist?(src_path)
    upload_mrb_via_picomodem(src: src_path, dst: '/home/app.mrb', port: espport)
  end
```

- [ ] **Step 8.3: Update ble_control_smoke callsite**

In `namespace :r2p2 do` `task :ble_control_smoke do`, find:

```ruby
    ENV['SRC'] = 'mrbgems/picoruby-stackchan-protocol/examples/application.rb'
    Rake::Task['r2p2:upload_mrb'].invoke
```

Replace with:

```ruby
    ENV['SRC'] = 'mrbgems/picoruby-stackchan-protocol/examples/application.rb'
    Rake::Task['r2p2:upload_appmrb'].invoke
```

- [ ] **Step 8.4: Update face_verify host SHA path**

In `task :face_verify do`, find the block that does:

```ruby
Bundler.with_unbundled_env do
  Dir.chdir(File.expand_path('mrbgems/picoruby-stackchan-protocol', __dir__)) do
    ok = system('bundle', 'exec', 'rake', 'test',
                "TESTOPTS=--name=FaceGoldenTest#test_#{face}_matches_golden")
    ...
  end
end
```

Replace with:

```ruby
Bundler.with_unbundled_env do
  Dir.chdir(__dir__) do  # project root, where test/face_golden_test.rb lives
    ok = system('bundle', 'exec', 'rake', 'test',
                "TESTOPTS=--name=FaceGoldenTest#test_#{face}_matches_golden")
    abort "[face_verify] host golden SHA FAIL for face=#{face}" unless ok
  end
end
```

- [ ] **Step 8.5: Verify rake -T lists all expected tasks**

Run: `bundle exec rake -T`
Expected output includes:
- `rake face:register_golden`
- `rake r2p2:build_flash`
- `rake r2p2:reset`
- `rake r2p2:upload_mrb`
- `rake r2p2:upload_appmrb`
- `rake r2p2:ble_control_smoke`
- `rake r2p2:face_verify`
- `rake test`

NOT present: `rake r2p2:upload` (deleted).

- [ ] **Step 8.6: Smoke-test face_verify host SHA leg without device**

Run:
```bash
bundle exec rake r2p2:face_verify FACE=neutral
```

Expected: host SHA assertion runs and PASSes. The device BLE leg will then attempt and likely FAIL since the device is in a known-broken state (we'll fix that in Task 14+). Note exit code; if non-zero from the BLE leg, that's expected. The important verification is the `[face_verify] host golden SHA PASS for face=neutral` line appears.

- [ ] **Step 8.7: Commit**

```bash
git add Rakefile
git commit -m "$(cat <<'EOF'
feat(rake): upload_mrb (DST required) + upload_appmrb (autostart /home/app.mrb)

Delete the legacy r2p2:upload task (on-device .rb compile path) that caused
a stack overflow in PicoRuby codegen. All deploys now route through host
picorbc compilation. Generic upload_mrb requires DST for use with the
picoruby load_path; upload_appmrb is the autostart-only convenience that
hard-codes /home/app.mrb.

Update ble_control_smoke callsite and face_verify host SHA path to point at
the new project-root test/ location.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Part 2: Deploy skills, documentation, memory cleanup

## Task 9: Atomic deploy skills (`stackchan-device-*`, 10 skills)

**Files:** create one `.claude/skills/<name>/SKILL.md` per skill.

Skill content contract: each `SKILL.md` starts with a YAML frontmatter (name + description), followed by markdown body covering: mode (subagent vs main), rake command + env vars, expected pass/fail signal, escalation hint.

- [ ] **Step 9.1: Create skills directory + slash commands directory**

```bash
mkdir -p .claude/skills .claude/commands
```

- [ ] **Step 9.2: Create `stackchan-device-build-flash` skill**

Create `.claude/skills/stackchan-device-build-flash/SKILL.md`:

```markdown
---
name: stackchan-device-build-flash
description: Build R2P2-ESP32 firmware and flash CoreS3 in one step (~5-10 min). Use when mrbgem layout, sdkconfig, picogem_init.c, or any firmware-side code changed. Always runs in a haiku subagent with a 600000ms timeout to keep verbose make logs out of main context.
---

# stackchan-device-build-flash

## Mode

Subagent (haiku), foreground, 600000ms (10 min) timeout.

Rationale: rake-compiler make logs and Test::Unit dot progress are extremely
verbose and would dilute main context. Subagent returns only pass/fail + the
final ~30 lines.

## Action

Dispatch a general-purpose haiku subagent with this prompt:

> Run `cd /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby && bundle exec rake r2p2:build_flash` in the foreground with a 600000ms timeout. Do not modify any code. Report exit code and the final 30 lines of output. Under 200 words.

## Pass / fail signal

- Exit 0 + `Hash of data verified` line in tail → success.
- Exit non-zero or `IRAM segment overflowed` / `link failed` / `picogem regen mismatch` → failure.

## Escalation

If FAIL with link error or symbol-missing, the mrbgem layout changed without
`picogem_init.c` regen. Run `stackchan-device-setup` instead (full host
picoruby rebuild + setup).
```

Create `.claude/commands/stackchan-device-build-flash.md`:

```markdown
---
description: Run R2P2-ESP32 build + flash via the stackchan-device-build-flash skill
---

Invoke the stackchan-device-build-flash skill.
```

- [ ] **Step 9.3: Create `stackchan-device-setup` skill**

Create `.claude/skills/stackchan-device-setup/SKILL.md`:

```markdown
---
name: stackchan-device-setup
description: Full R2P2-ESP32 host build + target setup (~10-20 min). Use on first checkout, target switch, or when build_flash fails due to picogem_init.c / gem layout drift. Always haiku subagent with 1200000ms timeout.
---

# stackchan-device-setup

## Mode

Subagent (haiku), 1200000ms (20 min) timeout.

## Action

Dispatch:

> Run `cd /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby && bundle exec rake r2p2:setup` in the foreground with a 1200000ms timeout. Do not modify any code. Report exit code and the final 30 lines. Under 200 words.

## Pass / fail signal

- Exit 0 → success. Follow up with `stackchan-device-build-flash`.
- Exit non-zero → consult R2P2-ESP32 sdkconfig / dependency state; manual intervention required.

## Escalation

Setup failures are usually environment issues (esp-idf export, swiftly env,
picoruby host build). Inspect output for the specific component that failed.
```

Create `.claude/commands/stackchan-device-setup.md`:

```markdown
---
description: Run R2P2-ESP32 setup via the stackchan-device-setup skill
---

Invoke the stackchan-device-setup skill.
```

- [ ] **Step 9.4: Create `stackchan-device-reset` skill**

Create `.claude/skills/stackchan-device-reset/SKILL.md`:

```markdown
---
name: stackchan-device-reset
description: RTS-pulse the CoreS3 to hard-reset and wait 15 s for cold-boot (escape hatch + cold-boot init + sleep_ms 3000 + BLE adv). Use after upload_appmrb to bring the new payload into effect.
---

# stackchan-device-reset

## Mode

Subagent (haiku), 30000ms timeout.

## Action

Dispatch:

> Run `cd /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby && bundle exec rake r2p2:reset` in the foreground, then sleep 15. Report exit code. Under 80 words.

## Pass / fail signal

- Rake exit 0 → device reset issued. Cold-boot timing is implicit (the 15s sleep covers escape hatch + init + BTstack yield + BLE adv).
- Rake exit non-zero → USB / serial driver problem. Check `ls /dev/cu.usbmodem*`.

## Escalation

If reset succeeds but the device does not subsequently respond, run
`stackchan-device-boot-verify` to capture the boot log and check for panic.
```

Create alias `.claude/commands/stackchan-device-reset.md` (same shape as build-flash command, replace name).

- [ ] **Step 9.5: Create `stackchan-device-upload-app` skill (no alias)**

Create `.claude/skills/stackchan-device-upload-app/SKILL.md`:

```markdown
---
name: stackchan-device-upload-app
description: host-compile SRC=path/to/app.rb to .mrb and upload as /home/app.mrb autostart payload via PicoModem (~7 s). Used internally by deploy-app / cold-recovery / full-rebuild / iterate chain skills. No slash alias.
---

# stackchan-device-upload-app

## Mode

Subagent (haiku), 120000ms timeout.

## Action

Dispatch:

> Run `cd /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby && bundle exec rake r2p2:upload_appmrb SRC=$SRC` in the foreground with a 120000ms timeout. SRC is the path to the application Ruby file relative to repo root. Do not modify any code. Report exit code, the picorbc compiled size line, and any FILE_ACK / DONE_ACK lines. Under 150 words.

## Required env

- `SRC` — path to application .rb file (e.g. `mrbgems/picoruby-stackchan-protocol/examples/application.rb`).

## Pass / fail signal

- Exit 0 + `DONE_ACK ok` → success.
- `FILE_ACK got nil` → device autostart loop occupies STDIN; escalate to wipe.
- `picorbc compilation failed` → script syntax error; fix application.rb.

## Escalation

`FILE_ACK got nil` → `stackchan-device-cold-recovery` (full wipe + retry).
```

- [ ] **Step 9.6: Create `stackchan-device-upload-lib` skill (no alias)**

Create `.claude/skills/stackchan-device-upload-lib/SKILL.md`:

```markdown
---
name: stackchan-device-upload-lib
description: host-compile a non-autostart .rb to .mrb and upload to DST under /home/lib/ or similar (~7 s). Used for picoruby load_path-resolvable helpers. No slash alias.
---

# stackchan-device-upload-lib

## Mode

Subagent (haiku), 120000ms timeout.

## Action

Dispatch:

> Run `cd /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby && bundle exec rake r2p2:upload_mrb SRC=$SRC DST=$DST` in the foreground with 120000ms timeout. Both SRC and DST are required env vars. Report exit code + DONE_ACK. Under 100 words.

## Required env

- `SRC` — path to source .rb
- `DST` — absolute device path ending in `.mrb` (e.g. `/home/lib/helper.mrb`)

## Pass / fail signal

Identical to upload-app; the only difference is DST is explicit.
```

- [ ] **Step 9.7: Create `stackchan-device-wipe` skill**

Create `.claude/skills/stackchan-device-wipe/SKILL.md`:

```markdown
---
name: stackchan-device-wipe
description: Erase the storage partition (0x210000-0x310000, 1 MB) via esptool + hard-reset (~7 s). Use when app.mrb autostart loops, FILE_ACK got nil persists, or shell is unreachable.
---

# stackchan-device-wipe

## Mode

Subagent (haiku), 60000ms timeout.

## Action

Dispatch:

> Run `cd /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby && bundle exec rake r2p2:wipe_storage` in the foreground with 60000ms timeout, then sleep 15 to let the device settle. Report exit code. Under 80 words.

## Pass / fail signal

- Exit 0 + `Erase operation completed successfully` → storage cleared.
- Exit non-zero → USB driver / esptool / port permission issue. Manual intervention.

## Escalation

If wipe itself fails, USB device may be gone or in download mode. Ask the
human to USB-replug. If wipe works but subsequent upload still hangs, run
`stackchan-device-full-rebuild`.
```

Create `.claude/commands/stackchan-device-wipe.md` as alias.

- [ ] **Step 9.8: Create `stackchan-device-capture-boot` skill (main mode)**

Create `.claude/skills/stackchan-device-capture-boot/SKILL.md`:

```markdown
---
name: stackchan-device-capture-boot
description: Run bin/capture-with-pty for a fixed duration (default 25 s) to capture device serial output to /tmp/boot.log. Main-context, not subagent — we need the raw log content for downstream analysis (Guru Meditation detection, panic dump extraction).
---

# stackchan-device-capture-boot

## Mode

Main context (NOT subagent).

Rationale: the captured log is consumed by `crash-analyze` or visual
inspection. Subagent summarization would lose panic dump details.

## Action

From main, run:

```bash
mkdir -p tmp/longrun
SECONDS=${SECONDS:-25}
LOG=${LOG:-/tmp/boot.log}
bin/capture-with-pty $SECONDS $LOG bundle exec rake r2p2:monitor
```

(`bin/capture-with-pty` uses expect to attach a pseudo-TTY, capture output
for $SECONDS, then send Ctrl-] to detach the monitor.)

## Required / optional env

- `SECONDS` — capture duration (default 25)
- `LOG` — output path (default `/tmp/boot.log`)

## Pass / fail signal

- File exists at `$LOG` and is non-empty → capture OK. Inspect for
  `Loading app.rb`, `[application] LCD + LED cold-boot done`,
  `Guru Meditation Error`, `Rebooting...`.

## Escalation

If panic dump present (`Guru Meditation Error`), invoke
`stackchan-device-crash-analyze` with `LOG=$LOG`.
```

Create `.claude/commands/stackchan-device-capture-boot.md` alias.

- [ ] **Step 9.9: Create `stackchan-device-crash-analyze` skill (no alias)**

Create `.claude/skills/stackchan-device-crash-analyze/SKILL.md`:

```markdown
---
name: stackchan-device-crash-analyze
description: Parse a /tmp/boot.log (or LOG=...) for Guru Meditation Error register dumps and resolve PC / backtrace addresses to symbols via xtensa-esp32s3-elf-addr2line against the local R2P2-ESP32.elf. Subagent (haiku) summarizes addr2line output. No slash alias — claude/AI driven.
---

# stackchan-device-crash-analyze

## Mode

Subagent (haiku), 60000ms timeout.

## Action

Dispatch:

> Read $LOG (default /tmp/boot.log). Extract any `Guru Meditation Error` PC, EXCVADDR, A0/A1/.., and Backtrace addresses. For each address, also try the variant with bit 31 cleared (`0x82xxxxxx` → `0x42xxxxxx`). Run xtensa-esp32s3-elf-addr2line against /Users/bash/dev/src/github.com/bash0C7/R2P2-ESP32/build/R2P2-ESP32.elf:
>
>     source /Users/bash/dev/src/github.com/bash0C7/esp-idf/export.sh && xtensa-esp32s3-elf-addr2line -pfiaC -e .../R2P2-ESP32.elf <addresses>
>
> Categorize each resolved function (mruby / BTstack / esp-idf / FreeRTOS / app). Report under 250 words.

## Required env

- `LOG` — path to boot log (default `/tmp/boot.log`)

## Pass / fail signal

This skill always succeeds; its output is the analysis. The "failure" mode
is "no panic in log" — then the skill reports "no Guru Meditation found".
```

- [ ] **Step 9.10: Create `stackchan-device-ble-smoke` skill (no alias)**

Create `.claude/skills/stackchan-device-ble-smoke/SKILL.md`:

```markdown
---
name: stackchan-device-ble-smoke
description: Send a single BLE NUS combo frame (face + LED) to the device and assert ACK via Mac CoreBluetooth (~20-40 s). Claude-driven HITL step, no human slash alias.
---

# stackchan-device-ble-smoke

## Mode

Subagent (haiku), 300000ms timeout.

## Action

Dispatch:

> Run `cd /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby && FACE=$FACE COLOR=$COLOR MODE=$MODE SIDE=$SIDE bundle exec rake r2p2:ble_control_smoke` foreground with 300000ms timeout. Do not modify code. Report exit code and any `[smoke] PASS` / `[smoke] FAIL` line verbatim. Under 150 words.

## Required env

- `FACE` (neutral/smile/joy/surprised/sad/angry)
- `COLOR` (e.g. red, blue, white)
- `MODE` (solid / breathing / blink)
- `SIDE` (left / right / both)

## Pass / fail signal

- `[smoke] PASS — face=<F> LED=<C> <M> (side=<S>)` → success. ACK received.
- Non-zero exit → connection / discovery / write / ACK failure. Check
  `[smoke] FAIL ...` line.

## Escalation

ACK failure usually means autostart payload mismatch (different Dispatcher
in app.mrb than the FACE_INDICES sent). Re-run with `stackchan-device-deploy-app`.
```

- [ ] **Step 9.11: Create `stackchan-device-face-verify` skill**

Create `.claude/skills/stackchan-device-face-verify/SKILL.md`:

```markdown
---
name: stackchan-device-face-verify
description: Two-leg face verification — host golden-SHA assert + device BLE write/ACK (~30 s total). Use after HITL approval to lock geometry against regression.
---

# stackchan-device-face-verify

## Mode

Subagent (haiku), 300000ms timeout.

## Action

Dispatch:

> Run `cd /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby && bundle exec rake r2p2:face_verify FACE=$FACE` foreground with 300000ms timeout. Report exit code and the two PASS lines (`[face_verify] host golden SHA PASS for face=...` and `[face_verify] PASS ...`) verbatim. Under 150 words.

## Required env

- `FACE` — name of registered face (e.g. sad, angry)

## Pass / fail signal

- Both PASS lines present and exit 0 → fully verified.
- `host golden SHA FAIL` → geometry drift on host; re-register golden if intentional.
- Host PASS but BLE leg fails → device payload mismatch; redeploy with `stackchan-device-deploy-app`.
```

Create `.claude/commands/stackchan-device-face-verify.md` alias.

- [ ] **Step 9.12: Commit atomic skills**

```bash
git add .claude/skills/stackchan-device-build-flash \
        .claude/skills/stackchan-device-setup \
        .claude/skills/stackchan-device-reset \
        .claude/skills/stackchan-device-upload-app \
        .claude/skills/stackchan-device-upload-lib \
        .claude/skills/stackchan-device-wipe \
        .claude/skills/stackchan-device-capture-boot \
        .claude/skills/stackchan-device-crash-analyze \
        .claude/skills/stackchan-device-ble-smoke \
        .claude/skills/stackchan-device-face-verify \
        .claude/commands/stackchan-device-build-flash.md \
        .claude/commands/stackchan-device-setup.md \
        .claude/commands/stackchan-device-reset.md \
        .claude/commands/stackchan-device-wipe.md \
        .claude/commands/stackchan-device-capture-boot.md \
        .claude/commands/stackchan-device-face-verify.md
git commit -m "$(cat <<'EOF'
feat(skills): add 10 atomic stackchan-device-* deploy skills + 6 slash aliases

build-flash / setup / reset / upload-app / upload-lib / wipe / capture-boot
/ crash-analyze / ble-smoke / face-verify. All but upload-app, upload-lib,
crash-analyze, and ble-smoke get slash command aliases for human use.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: Chain deploy skills (`stackchan-device-{deploy-app,cold-recovery,full-rebuild,boot-verify,iterate}`)

- [ ] **Step 10.1: Create `stackchan-device-deploy-app` skill**

Create `.claude/skills/stackchan-device-deploy-app/SKILL.md`:

```markdown
---
name: stackchan-device-deploy-app
description: Upload application .mrb and reset the device (upload-app + reset, ~20 s). Use during dev iteration when application.rb changed and the device should adopt the new payload.
---

# stackchan-device-deploy-app

## Mode

Chain — invokes `stackchan-device-upload-app` then `stackchan-device-reset`
in sequence.

## Action

1. Invoke `stackchan-device-upload-app` with `SRC=$SRC` (default
   `mrbgems/picoruby-stackchan-protocol/examples/application.rb`).
2. On success, invoke `stackchan-device-reset`.
3. Report combined status.

## Required env

- `SRC` (optional, defaults to application.rb)

## Pass / fail signal

- Upload PASS + reset PASS → deploy complete. Cold-boot should begin.
- Upload `FILE_ACK got nil` → escalate to `stackchan-device-cold-recovery`.
```

Create `.claude/commands/stackchan-device-deploy-app.md` alias.

- [ ] **Step 10.2: Create `stackchan-device-cold-recovery` skill**

Create `.claude/skills/stackchan-device-cold-recovery/SKILL.md`:

```markdown
---
name: stackchan-device-cold-recovery
description: Standard recovery when device autostart is misbehaving — wipe storage, upload application, reset (~30 s total). Use when FILE_ACK got nil persists, autostart loops, or LCD is unexpectedly blank after a deploy attempt.
---

# stackchan-device-cold-recovery

## Mode

Chain.

## Action

1. Invoke `stackchan-device-wipe` (clears /home/app.mrb).
2. Invoke `stackchan-device-upload-app` with `SRC=$SRC` (default
   `mrbgems/picoruby-stackchan-protocol/examples/application.rb`).
3. Invoke `stackchan-device-reset`.
4. Report final status.

## Required env

- `SRC` (optional, defaults to application.rb)

## Escalation

If still failing after cold-recovery (2 attempts), escalate to
`stackchan-device-full-rebuild` (the firmware itself may be stale).
```

Create alias.

- [ ] **Step 10.3: Create `stackchan-device-full-rebuild` skill**

Create `.claude/skills/stackchan-device-full-rebuild/SKILL.md`:

```markdown
---
name: stackchan-device-full-rebuild
description: Heaviest recovery — build_flash firmware, wipe storage, upload application, reset (~5-10 min). Use when mrbgem layout / sdkconfig / driver code changed, OR when cold-recovery fails repeatedly.
---

# stackchan-device-full-rebuild

## Mode

Chain.

## Action

1. Invoke `stackchan-device-build-flash`.
2. Invoke `stackchan-device-wipe`.
3. Invoke `stackchan-device-upload-app` with `SRC=$SRC`.
4. Invoke `stackchan-device-reset`.
5. Report final status.

## Required env

- `SRC` (optional, defaults to application.rb)

## Escalation

If build_flash itself fails, run `stackchan-device-setup` first then retry.
```

Create alias.

- [ ] **Step 10.4: Create `stackchan-device-boot-verify` skill**

Create `.claude/skills/stackchan-device-boot-verify/SKILL.md`:

```markdown
---
name: stackchan-device-boot-verify
description: Reset and capture boot log; if a panic dump is detected, automatically resolve crash addresses via crash-analyze. Use to confirm cold-boot completes after deploy.
---

# stackchan-device-boot-verify

## Mode

Chain — subagent for reset, main for capture, subagent again for analyze.

## Action

1. Invoke `stackchan-device-reset`.
2. Invoke `stackchan-device-capture-boot` with `SECONDS=25 LOG=/tmp/boot.log`.
3. Inspect `/tmp/boot.log` for `Guru Meditation Error`:
   - Present → invoke `stackchan-device-crash-analyze` with `LOG=/tmp/boot.log`. Report the analysis.
   - Absent → check for `[application] LCD + LED cold-boot done` and `HCI WORKING — advertising`. Report success markers found.

## Pass / fail signal

- `[application] LCD + LED cold-boot done` + no panic → cold-boot completed.
- `Guru Meditation Error` → analysis follows.
- Neither marker nor panic → device output truncated or hung; consider increasing SECONDS.
```

Create alias.

- [ ] **Step 10.5: Create `stackchan-device-iterate` skill**

Create `.claude/skills/stackchan-device-iterate/SKILL.md`:

```markdown
---
name: stackchan-device-iterate
description: Full dev iteration cycle — upload application, reset, capture boot log, auto-analyze panic if any (~50 s). Use for the standard "I changed application.rb, did it work?" loop.
---

# stackchan-device-iterate

## Mode

Chain.

## Action

1. Invoke `stackchan-device-upload-app` with `SRC=$SRC`.
2. Invoke `stackchan-device-reset`.
3. Invoke `stackchan-device-capture-boot` with `SECONDS=25`.
4. If panic in log → invoke `stackchan-device-crash-analyze`.
5. Report combined: upload OK, reset OK, boot markers found, panic Y/N + analysis.

## Required env

- `SRC` (optional, defaults to application.rb)

## Escalation

- Upload fail → `stackchan-device-cold-recovery`
- Persistent panic → debug session, not another iteration
```

Create alias.

- [ ] **Step 10.6: Commit chain skills + aliases**

```bash
git add .claude/skills/stackchan-device-deploy-app \
        .claude/skills/stackchan-device-cold-recovery \
        .claude/skills/stackchan-device-full-rebuild \
        .claude/skills/stackchan-device-boot-verify \
        .claude/skills/stackchan-device-iterate \
        .claude/commands/stackchan-device-deploy-app.md \
        .claude/commands/stackchan-device-cold-recovery.md \
        .claude/commands/stackchan-device-full-rebuild.md \
        .claude/commands/stackchan-device-boot-verify.md \
        .claude/commands/stackchan-device-iterate.md
git commit -m "$(cat <<'EOF'
feat(skills): add 5 chain stackchan-device-* deploy skills + slash aliases

deploy-app / cold-recovery / full-rebuild / boot-verify / iterate compose
the atomic skills into common dev / recovery flows. Each gets a slash
command alias for human invocation.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 11: Update `README.md`

**Files:**
- Modify: `README.md` (or create if absent)

- [ ] **Step 11.1: Inspect existing README**

Run: `cat README.md 2>/dev/null || echo "README absent"`

- [ ] **Step 11.2: Write or extend README**

Either create or extend `README.md` to include these sections (if absent, write fresh; if present, weave in):

```markdown
# stackchan-picoruby

StackChan AI desktop robot running PicoRuby on R2P2-ESP32 (CoreS3).

## Project structure

| Layer | Location | Build cycle |
|---|---|---|
| Drivers | `mrbgems/picoruby-*` + R2P2-ESP32 ports | `stackchan-device-build-flash` (~5-10 min) |
| Protocol framework (FrameParser) | `mrbgems/picoruby-stackchan-protocol` | `stackchan-device-build-flash` |
| Application (Face DSL, Dispatcher, BLE peripheral) | `mrbgems/picoruby-stackchan-protocol/examples/application.rb` | `stackchan-device-deploy-app` (~20 s) |
| Host tests | `test/`, `lib/ruby_class_extract.rb` | `bundle exec rake test` |

The single `application.rb` is the autostart payload; on-device requires
only resolve under PicoRuby. Host tests load the file via prism AST
extraction (`lib/ruby_class_extract.rb`).

## Dev iteration

```
edit application.rb -> rake test            # host tests (~3 s)
                    -> /stackchan-device-iterate  # device deploy + boot verify (~50 s)
```

## Deploy skills

| Skill | Slash alias | Purpose |
|---|---|---|
| stackchan-device-build-flash | yes | rebuild firmware + flash |
| stackchan-device-setup | yes | host picoruby + target setup |
| stackchan-device-reset | yes | RTS pulse + 15 s settle |
| stackchan-device-wipe | yes | erase /home storage partition |
| stackchan-device-capture-boot | yes | log device serial to /tmp/boot.log |
| stackchan-device-face-verify | yes | host golden SHA + device ACK |
| stackchan-device-deploy-app | yes | upload .mrb + reset |
| stackchan-device-cold-recovery | yes | wipe + redeploy + reset |
| stackchan-device-full-rebuild | yes | build_flash + cold-recovery |
| stackchan-device-boot-verify | yes | reset + capture + auto-analyze |
| stackchan-device-iterate | yes | upload + reset + capture + analyze |

Internal (no slash alias): upload-app, upload-lib, crash-analyze, ble-smoke
— driven by claude during chain flows.

## Recovery hierarchy

If a deploy goes wrong, escalate in this order:

1. `/stackchan-device-cold-recovery` — wipe + retry, ~30 s
2. `/stackchan-device-full-rebuild` — rebuild firmware first, ~5-10 min
3. Human help — USB replug / monitor + `rm /home/app.mrb` / download mode

Do not iterate on step 1 more than twice; escalate.

## Host tests

```
bundle install
bundle exec rake test
```

Tests cover Face geometry, Dispatcher routing, golden-SHA regression, and
the RubyClassExtract library itself. They DO NOT exercise on-device
behavior — that is verified via `/stackchan-device-iterate` and
`/stackchan-device-face-verify`.
```

- [ ] **Step 11.3: Commit**

```bash
git add README.md
git commit -m "$(cat <<'EOF'
docs(readme): document project structure, deploy skills, iteration flow

Capture the firmware/application boundary, host test workflow via
ruby_class_extract, and the recovery escalation hierarchy. New developers
get the iterate cycle in one paragraph.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 12: Update `CLAUDE.md` with the new discipline

**Files:**
- Modify: `CLAUDE.md` (project root)

- [ ] **Step 12.1: Read current CLAUDE.md**

Run: `cat CLAUDE.md`

Locate the section about "PicoModem upload timing" and "autostart 詰まり recovery の階層".

- [ ] **Step 12.2: Replace upload + recovery sections**

Replace the existing "PicoModem upload timing" section with:

```markdown
### Device deploy: skills only, no ad-hoc rake

All device interactions go through `stackchan-device-*` skills (slash
commands available for the human-facing subset). Do NOT invoke `rake
r2p2:*` directly from main context — use the skill so output stays
bounded and the chain composition is auditable.

The `.rb` direct-upload path is forbidden. Always go through `upload_mrb`
(generic) or `upload_appmrb` (autostart); on-device PicoRuby cannot
compile application.rb-scale scripts (codegen stack overflow). Host
picorbc compilation is mandatory.

Iteration cycle:

| Step | Skill |
|---|---|
| edit + host test | `bundle exec rake test` |
| device iterate | `/stackchan-device-iterate` |
| HITL face check | `/stackchan-device-face-verify FACE=...` |

Recovery escalation (escalate after 2 tries):

1. `/stackchan-device-cold-recovery`
2. `/stackchan-device-full-rebuild`
3. Human-driven recovery (USB replug, monitor manual, download mode)
```

Replace "autostart 詰まり recovery の階層" with a one-liner:

```markdown
### Recovery

See `stackchan-device-cold-recovery` / `-full-rebuild` skills and the
README recovery section. Memory entries describing the old wipe → flash
hierarchy are obsolete; the skills encode the same logic and supersede
them.
```

Add a new section about business-logic boundary:

```markdown
### Firmware vs application boundary

- Firmware (mrbgems, requires `build_flash`): hardware drivers + stable
  protocol framework (`StackchanProtocol::FrameParser` only).
- Application (`mrbgems/picoruby-stackchan-protocol/examples/application.rb`,
  deploy via `upload_appmrb`): all StackChan business logic — `Face` DSL,
  `Dispatcher`, BLE peripheral, cold-boot init.
- Host tests load application class definitions via prism AST through
  `lib/ruby_class_extract.rb`. Application code must keep class
  definitions free of `< BLE` patterns at the class-body top level so the
  exclusion filter can skip them cleanly.
```

- [ ] **Step 12.3: Commit**

```bash
git add CLAUDE.md
git commit -m "$(cat <<'EOF'
docs(claude.md): mandate skill-only device ops, document app/firmware boundary

The legacy 'rake r2p2:upload SRC=...rb' guidance is removed. mrb-only
deploys via stackchan-device-* skills are the only supported path.
Business logic lives in application.rb; firmware retains only drivers
and FrameParser.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 13: Memory cleanup

**Files:**
- Modify: `/Users/bash/.claude/projects/-Users-bash-dev-src-github-com-bash0C7-stackchan-picoruby/memory/MEMORY.md`
- Delete: superseded memory files (listed below)

- [ ] **Step 13.1: List current memory files**

```bash
ls /Users/bash/.claude/projects/-Users-bash-dev-src-github-com-bash0C7-stackchan-picoruby/memory/
```

- [ ] **Step 13.2: Identify entries to forget**

Forget (delete the file + remove the MEMORY.md line):

- `project_ble_phase3_wipe_storage_recovery.md` — superseded by the cold-recovery skill.

For any entry whose sole content is "use `rake r2p2:upload SRC=...rb`" guidance, delete that paragraph (the entry as a whole may still hold other useful info).

- [ ] **Step 13.3: Delete superseded memory files**

```bash
rm /Users/bash/.claude/projects/-Users-bash-dev-src-github-com-bash0C7-stackchan-picoruby/memory/project_ble_phase3_wipe_storage_recovery.md
```

- [ ] **Step 13.4: Update MEMORY.md index**

Edit `/Users/bash/.claude/projects/-Users-bash-dev-src-github-com-bash0C7-stackchan-picoruby/memory/MEMORY.md`, remove the bullet line referencing `project_ble_phase3_wipe_storage_recovery.md`.

Add a new entry:

```
- [App-side business logic + deploy skills (2026-05-19)](project_design_d_app_side_and_skills.md) — Face/Dispatcher in application.rb, FrameParser only in firmware, stackchan-device-* skills for all device ops
```

- [ ] **Step 13.5: Create the new project memory file**

Create `/Users/bash/.claude/projects/-Users-bash-dev-src-github-com-bash0C7-stackchan-picoruby/memory/project_design_d_app_side_and_skills.md`:

```markdown
---
name: design-d-app-side-and-skills
description: "2026-05-19 — Design D shipped: Face DSL + Dispatcher live in application.rb (StackchanApp namespace), only FrameParser remains in firmware. .rb direct-upload path deleted (caused stack overflow in PicoRuby codegen). All device ops standardized via stackchan-device-* skills."
metadata:
  type: project
---

**Shipped 2026-05-19** (see `docs/superpowers/specs/2026-05-19-app-side-business-logic-and-skills.md`):

- `mrbgems/picoruby-stackchan-protocol/examples/application.rb` now inlines Face DSL + Dispatcher under `StackchanApp` namespace.
- `mrbgems/picoruby-stackchan-protocol/mrblib/stackchan_protocol.rb` shrunk to FrameParser wrapper only.
- `lib/ruby_class_extract.rb` — prism AST extract + tmpfile load for host CRuby tests against the autostart deployable.
- Rakefile: `:upload` deleted. `:upload_mrb` requires DST. `:upload_appmrb` is autostart-only.
- 15 `stackchan-device-*` skills + 11 slash aliases under `.claude/skills/` and `.claude/commands/`.
- README + CLAUDE.md updated with new discipline.

**How to apply:**

- Device deploys: always via `/stackchan-device-iterate` or atomic skill, never `rake r2p2:upload*` direct.
- Application code lives in `examples/application.rb` — Face geometry tweaks, new Dispatcher keys, cold-boot adjustments all go there, no `build_flash` needed.
- Firmware changes (driver gems, FrameParser, sdkconfig) need `/stackchan-device-full-rebuild`.

**Related:** [[project_kawaii_ai_phase_a_code_complete]] (Phase A — Sad/Angry goldens registered during this migration's Task 16).
```

- [ ] **Step 13.6: Commit dotfiles repo (if applicable)**

The memory directory is under `~/.claude/`, which per global CLAUDE.md is managed via GNU stow from iCloud dotfiles. If a dotfiles git repo applies, commit there:

```bash
cd ~/.claude  # adjust if dotfiles repo root is elsewhere
git add projects/-Users-bash-dev-src-github-com-bash0C7-stackchan-picoruby/memory/
git commit -m "memory: cleanup post Design D migration (forget wipe_storage recovery)"
```

If not under git management, no commit needed.

---

## Part 3: Bring the device up on the new path (Tasks 14-16)

## Task 14: Bring the device up — full-rebuild then boot-verify

- [ ] **Step 14.1: Run full-rebuild**

Invoke `/stackchan-device-full-rebuild` (or via skill).

Expected: build_flash succeeds (~5-10 min), wipe succeeds, upload_appmrb succeeds (FILE_ACK + DONE_ACK), reset issued, 15 s settle.

If build_flash fails with picogem regen error → run `/stackchan-device-setup` then retry full-rebuild.

- [ ] **Step 14.2: Run boot-verify**

Invoke `/stackchan-device-boot-verify`.

Expected: `[application] LCD + LED cold-boot done` in log, no `Guru Meditation Error`. If panic occurs, crash-analyze runs automatically; diagnose from there.

- [ ] **Step 14.3: HITL #0 — confirm Neutral face on LCD**

Ask the user:

> Phase A device test: cold-boot complete. Please confirm the LCD shows **Face::Neutral** (two white eye dots at y≈100 + a single horizontal mouth line at y=140). OK / NOT OK / different shape (describe).

If NOT OK → debug. Most likely root cause is either still on-device compile (check `Loading app.rb` in the boot log) or a different cold-boot defect. Use `/stackchan-device-boot-verify` to inspect.

If OK → proceed to Task 15.

---

## Task 15: Phase A HITL — Sad and Angry visual confirmation + golden registration

- [ ] **Step 15.1: Dispatch sad smoke**

Invoke `stackchan-device-ble-smoke` with:

- FACE=sad
- COLOR=blue
- MODE=solid
- SIDE=both

Expected output: `[smoke] PASS — face=sad LED=blue solid (side=both)`.

- [ ] **Step 15.2: HITL #1 — confirm sad on LCD**

Ask the user:

> Phase A device test: Sad face dispatched. Please confirm:
> 1. **Mouth corners droop down** (frown shape, opposite of smile).
> 2. Eyes unchanged.
> 3. No brows visible.
> 4. **LED**: both sides solid blue.
> Reply OK / NOT OK (and describe what's wrong).

If NOT OK → tweak DELTA_Y in `application.rb` `Face::Sad`, re-run host tests (geometry test FAIL is expected if you adjusted; update test values), re-run `/stackchan-device-deploy-app`, re-run Step 15.1.

- [ ] **Step 15.3: Dispatch angry smoke**

Invoke `stackchan-device-ble-smoke` with:

- FACE=angry
- COLOR=red
- MODE=solid
- SIDE=both

Expected: `[smoke] PASS — face=angry LED=red solid (side=both)`.

- [ ] **Step 15.4: HITL #2 — confirm angry on LCD**

Ask the user:

> Phase A device test: Angry face dispatched. Please confirm:
> 1. **V-shaped brows** above each eye, inner ends pointing down-inward (like ╲ ╱).
> 2. Mouth is a straight horizontal line.
> 3. Eyes unchanged.
> 4. **LED**: both sides solid red.
> Reply OK / NOT OK.

If NOT OK → tweak BROW_OFFSET_Y / BROW_HALF_LENGTH / BROW_INNER_DROP in `application.rb` `Face::Angry`, re-run host + deploy + step 15.3.

- [ ] **Step 15.5: Register sad and angry goldens**

After BOTH HITLs pass:

```bash
bundle exec rake face:register_golden FACE=sad
bundle exec rake face:register_golden FACE=angry
```

Expected output for each: `[face:register_golden] wrote ...face_<name>.sha256 sha=<64-hex>`.

- [ ] **Step 15.6: Run full golden test, confirm 6 PASS 0 OMIT**

```bash
bundle exec rake test TESTOPTS="--name=/FaceGolden/"
```

Expected: 6 tests, 6 PASS, 0 OMIT, 0 FAIL.

- [ ] **Step 15.7: Run `stackchan-device-face-verify` for sad and angry**

Invoke skill twice: once with `FACE=sad`, once with `FACE=angry`.

Expected both: `[face_verify] host golden SHA PASS for face=...` AND `[face_verify] PASS — face=... host SHA matched + device ACK received`.

- [ ] **Step 15.8: Commit goldens (separate commits for sad and angry)**

Delegate to a general-purpose subagent (per project rule: 1 invocation = 1 commit):

Subagent prompt 1:

> In /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby, stage only spec/golden/face_sad.sha256 and commit with this exact message via heredoc:
>
> test(face): register HITL-approved golden for Face::Sad
>
> Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
>
> Do not push. Report the resulting SHA.

Subagent prompt 2:

> In /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby, stage only spec/golden/face_angry.sha256 and commit with this exact message:
>
> test(face): register HITL-approved golden for Face::Angry
>
> Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
>
> Do not push. Report the resulting SHA.

---

## Task 16: Update Phase A memory + close out

- [ ] **Step 16.1: Update project_kawaii_ai_phase_a_code_complete memory**

Edit `/Users/bash/.claude/projects/-Users-bash-dev-src-github-com-bash0C7-stackchan-picoruby/memory/project_kawaii_ai_phase_a_code_complete.md`:

- Change frontmatter `description` to indicate Phase A complete (sad/angry HITL closed).
- Remove the "HITL gate pending" section.
- Add a final section linking to `[[project_design_d_app_side_and_skills]]` noting the migration that closed Phase A.
- Update the "Shipped" table to include the two golden commits from Task 15.8.

- [ ] **Step 16.2: Update MEMORY.md description**

Edit MEMORY.md, change the Phase A code-complete entry's hook from "HITL (build_flash + visual + sad/angry golden) is device 再接続後" to "HITL gate cleared 2026-05-19, Sad/Angry goldens registered".

- [ ] **Step 16.3: Optional: commit dotfiles memory updates**

If under git management, commit per the same flow as Task 13.6.

- [ ] **Step 16.4: Final status report to user**

```
Design D 完了 + Phase A HITL closed.
- Face/Dispatcher in application.rb (StackchanApp namespace)
- FrameParser remains in firmware
- 15 stackchan-device-* skills + 11 slash aliases
- Sad/Angry goldens registered, all 6 face_verify pass
Next: Phase B (servo) plan write.
```

---

## Self-review

### Spec coverage

- Goal #1 (Face + Dispatcher to app) → Tasks 3, 4
- Goal #2 (forbid on-device .rb compile) → Task 8 (upload deletion)
- Goal #3 (stackchan-device-* skills) → Tasks 9, 10
- Components: firmware shrink → Task 7; application inline → Tasks 3, 4; ruby_class_extract → Task 1; test scaffold → Task 2; goldens → Tasks 5, 6
- Data flow: implicit in Tasks 3, 4 (Face & Dispatcher migration preserves behavior)
- Rakefile changes → Task 8
- Migration order spec steps 1-14 → Tasks 1-16
- Doc updates → Tasks 11, 12
- Memory cleanup → Task 13
- Phase A HITL → Tasks 14, 15
- Final memory close-out → Task 16
- Risks (golden SHA drift, mrbgem shrink build failure, residual cold-boot crash, BLE class extraction) → covered in Tasks 5, 7, 14 escalation hints

### Type / signature consistency

- `StackchanApp::Face::*` referenced in Tasks 3, 4, 5, 6, 11, 13, 15 — consistent.
- `StackchanApp::Dispatcher` referenced in Tasks 4, 11, 13 — consistent.
- `StackchanProtocol::FrameParser` referenced in Tasks 7 (mrbgem-only), 11 — consistent.
- `RubyClassExtract.load_classes_from(path, exclude_superclasses:)` signature consistent across Tasks 1, 2.
- `upload_mrb_via_picomodem(src:, dst:, port:)` helper signature consistent in Task 8.
- `face:register_golden FACE=` interface consistent across Tasks 6, 15.

### Placeholder scan

None remaining. All code blocks complete.

### Scope

11 spec-mandated migration steps decomposed into 16 implementation tasks (each ≤10 steps). HITL tasks (14, 15) require human + device. Tasks 1-13 are pure host work.

---

## Execution

After this plan is saved and committed, the next step is to invoke one of:

- **superpowers:subagent-driven-development** (recommended — many small TDD tasks benefit from fresh subagent per task, fast iteration)
- **superpowers:executing-plans** (inline batch execution with checkpoints)
