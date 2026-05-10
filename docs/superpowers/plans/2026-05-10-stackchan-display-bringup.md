# stackchan-display bring-up Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Boot R2P2-ESP32 (mruby VM) on M5Stack CoreS3, ship a Pure-Ruby `picoruby-ili9342` LCD driver mrbgem, and demonstrate three positive ｽﾀｯｸﾁｬﾝ facial expressions (`neutral` / `smile` / `joy`) by procedural mouth-curve drawing.

**Architecture:** Pure Ruby driver depends on `picoruby-spi` and `picoruby-gpio`. Built into `bash0C7/R2P2-ESP32` fork via gembox path-direct reference. Faces drawn at example-script level (not in driver), with eyes constant across all 3 expressions and only the mouth's vertical curve delta changing.

**Tech Stack:** PicoRuby (mruby VM build), R2P2-ESP32 component, ESP-IDF v5.4, picoruby-spi / picoruby-gpio / picoruby-machine. Host-side tests in CRuby with `test-unit` + `picoruby-picotest`.

**Reference repos (read-only):**
- `/Users/bash/dev/src/github.com/m5stack/StackChan` — official C++ firmware. Pin numbers and init sequence source-of-truth.
- `/Users/bash/dev/src/github.com/bash0C7/picoruby-mpu6886` — driver mrbgem reference shape.

**Working repos:**
- `/Users/bash/dev/src/github.com/m5stack/stackchan-picoruby` — this plan's main edit target.
- `/Users/bash/dev/src/github.com/bash0C7/R2P2-ESP32` — fork to add CoreS3 + ili9342 build hooks.
- `/Users/bash/dev/src/github.com/bash0C7/picoruby` — fork (use only if a picoruby internal patch becomes needed).

**TDD discipline:** Per `~/dev/src/CLAUDE.md`, RED / GREEN / REFACTOR are independent commits. Test runs over `bundle exec rake test` are delegated to a `general-purpose` subagent which returns only pass/fail + test count.

**Hardware checkpoints:** Tasks marked **🔌 HARDWARE** require physical CoreS3 access (flash, observe screen, reboot). Pause subagent flow at these tasks for user verification.

---

## Phase A: Pre-flight

### Task 1: Verify environment + remotes

**Files:**
- Modify: `/Users/bash/dev/src/github.com/bash0C7/R2P2-ESP32/.git/config` (via `git remote add`)

- [ ] **Step 1: Verify ESP-IDF v5.4 is on PATH**

```bash
idf.py --version 2>&1 | head -3
```

Expected: line containing `v5.4` or `release/v5.4`. If not, **STOP** and ask the user to install/source ESP-IDF v5.4 — this plan cannot proceed without it.

- [ ] **Step 2: Verify required forks are clone-present**

```bash
ls -d /Users/bash/dev/src/github.com/bash0C7/picoruby /Users/bash/dev/src/github.com/bash0C7/R2P2-ESP32 /Users/bash/dev/src/github.com/picoruby/picoruby /Users/bash/dev/src/github.com/m5stack/StackChan
```

Expected: all four paths exist. If any missing, abort and report.

- [ ] **Step 3: Add upstream remote to bash0C7/R2P2-ESP32**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/R2P2-ESP32 && git remote add upstream https://github.com/picoruby/R2P2-ESP32.git && git remote -v
```

Expected: 4 lines (origin fetch/push, upstream fetch/push).

- [ ] **Step 4: Fetch upstream + verify HEAD matches what we surveyed**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/R2P2-ESP32 && git fetch upstream && git log -1 upstream/master --oneline
```

Expected: top commit roughly `0a453db` or newer (survey was at `0a453db` 2026-05-10).

- [ ] **Step 5: Sync bash0C7 fork to upstream master if behind**

Compare `git log -1 upstream/master` and `git log -1 origin/master`. If `origin` is behind, ask user before merging — do not merge silently.

- [ ] **Step 6: Commit nothing (this task is verification only)**

No commit; record findings as a brief report to user (ESP-IDF version, upstream HEAD, sync state).

---

### Task 2: License compatibility check on upstream M5Stack code

**Files:**
- Read: `/Users/bash/dev/src/github.com/m5stack/StackChan/firmware/main/hal/board/stackchan_display.cc` header
- Read: any `LICENSE`, `LICENSE.md`, `COPYING` at the StackChan repo root or inside `firmware/`
- Create: `/Users/bash/dev/src/github.com/m5stack/stackchan-picoruby/docs/upstream-license-note.md`

- [ ] **Step 1: Check for license files**

```bash
ls /Users/bash/dev/src/github.com/m5stack/StackChan/{LICENSE,LICENSE.md,COPYING,firmware/LICENSE}* 2>&1 | grep -v 'No such'
```

- [ ] **Step 2: Check SPDX header inside `stackchan_display.cc`**

```bash
head -8 /Users/bash/dev/src/github.com/m5stack/StackChan/firmware/main/hal/board/stackchan_display.cc
```

Expected: an SPDX-License-Identifier line, e.g. `MIT`. If not present, **STOP** and ask the user how to handle re-implementation (we may need to write the init sequence from the ILI9342 datasheet directly instead of from the C++).

- [ ] **Step 3: Document the finding**

Create `/Users/bash/dev/src/github.com/m5stack/stackchan-picoruby/docs/upstream-license-note.md`:

```markdown
# Upstream license note

Source: `m5stack/StackChan@<commit>` (`firmware/main/hal/board/stackchan_display.cc`)

License found: <verbatim SPDX-License-Identifier or repo LICENSE summary>

Reuse decision: <can transcribe init bytes / pin constants verbatim — yes/no — and reasoning>

This file documents the legal basis for transcribing pin numbers and ILI9342
initialization byte sequences from the upstream C++ source into our Pure-Ruby
mrbgem `picoruby-ili9342`. Replace `<...>` placeholders with the actual SPDX id
and commit hash on completion.
```

Replace placeholders with real values from steps 1-2.

- [ ] **Step 4: Commit**

```bash
cd /Users/bash/dev/src/github.com/m5stack/stackchan-picoruby && git add docs/upstream-license-note.md && git commit -m "docs: record upstream license basis for ILI9342 reuse"
```

---

### Task 3: Extract ILI9342 init bytes + pin numbers from upstream

**Files:**
- Read: `/Users/bash/dev/src/github.com/m5stack/StackChan/firmware/main/hal/board/stackchan_display.cc` (full file)
- Read: `/Users/bash/dev/src/github.com/m5stack/StackChan/firmware/main/hal/board/config.h`
- Read: `/Users/bash/dev/src/github.com/m5stack/StackChan/firmware/main/hal/board/stackchan_display.h`
- Create: `/Users/bash/dev/src/github.com/m5stack/stackchan-picoruby/mrbgems/picoruby-ili9342/docs/cores3-pinout-and-init.md`

- [ ] **Step 1: Read display.cc and identify the init function**

Look for `lgfx::Panel_ILI9342` or similar instantiation, and any `cmds[]` / `init_cmds[]` / `setup()` block that issues SPI command bytes via `dc_pin = LOW` then payload bytes.

- [ ] **Step 2: Extract pin numbers**

From `config.h` / `stackchan_display.h` / `display.cc`, identify:
- `LCD_SPI_HOST` (e.g. SPI2_HOST / SPI3_HOST)
- `LCD_SCK_PIN` / `LCD_MOSI_PIN` (CIPO not used for write-only LCD)
- `LCD_CS_PIN`
- `LCD_DC_PIN` (data/command)
- `LCD_RST_PIN`
- `LCD_BL_PIN` (backlight)
- `LCD_SPI_FREQ` (Hz)
- panel width × height (320 × 240)
- default rotation / `MADCTL` value used at boot

If a pin is fan-out via the PY32 IO Expander (`PY32IOExpander_Class`) instead of a direct GPIO, **STOP** and report: that pin needs IO-expander I2C access and is out of scope for this spec.

- [ ] **Step 3: Extract the init command sequence**

For each command issued during init, record:
- command byte (e.g. `0x36` for MADCTL)
- payload bytes (zero or more)
- post-command delay (ms), if any

Format the result as a Ruby-array literal — this is what we'll paste into `mrblib/ili9342.rb` later:

```ruby
# Each entry: [cmd_byte, [payload_bytes...], delay_ms]
INIT_COMMANDS = [
  [0x01, [],                  120],   # SWRESET
  [0x11, [],                  120],   # SLPOUT
  # ...
  [0x29, [],                    0],   # DISPON
].freeze
```

- [ ] **Step 4: Save extracted data**

Create `mrbgems/picoruby-ili9342/docs/cores3-pinout-and-init.md` with:
- Section "Pin numbers (CoreS3)" — table of role → GPIO number → `picoruby-spi/gpio` `unit:` name
- Section "Init command sequence" — the Ruby-array literal
- Section "MADCTL rotation map" — 4 values for `:portrait` / `:landscape` / `:portrait_flip` / `:landscape_flip`
- Section "Source" — exact upstream file path + commit SHA

- [ ] **Step 5: Commit**

```bash
cd /Users/bash/dev/src/github.com/m5stack/stackchan-picoruby && mkdir -p mrbgems/picoruby-ili9342/docs && git add mrbgems/picoruby-ili9342/docs/cores3-pinout-and-init.md && git commit -m "docs(ili9342): extract CoreS3 pinout and ILI9342 init sequence from upstream"
```

---

## Phase B: Vanilla R2P2-ESP32 on CoreS3

### Task 4: 🔌 HARDWARE — flash vanilla R2P2-ESP32 mruby VM build to CoreS3

**Files:**
- Possibly create: `/Users/bash/dev/src/github.com/bash0C7/R2P2-ESP32/sdkconfigs/cores3` (only if existing fragments are insufficient)

- [ ] **Step 1: Build vanilla R2P2-ESP32 with picoruby (mruby VM) target esp32s3 + usb_console + spiram**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/R2P2-ESP32 && export SDKCONFIG_DEFAULTS="sdkconfigs/usb_console;sdkconfigs/spiram" && rake setup_esp32s3 && rake build
```

Expected: build succeeds, `build/R2P2-ESP32.bin` (or similar) produced.

If `setup_esp32s3` task name differs, run `rake -T` first to find the right task.

- [ ] **Step 2: Connect CoreS3 via USB-C and flash**

User: hold any required boot button on CoreS3 if needed, then:

```bash
cd /Users/bash/dev/src/github.com/bash0C7/R2P2-ESP32 && rake flash
```

Expected: flash completes without error.

- [ ] **Step 3: Open serial monitor and verify REPL prompt**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/R2P2-ESP32 && rake monitor
```

Expected: R2P2 banner + `> ` prompt within 5 seconds of reset. Press Enter, see fresh prompt.

- [ ] **Step 4: Smoke-test PicoRuby VM in REPL**

In the REPL:

```ruby
> 1 + 1
=> 2
> require 'gpio'
=> true
> require 'spi'
=> true
```

Expected: each line returns successfully. If `require 'spi'` errors, the spi mrbgem is missing from the build_config — fix in Task 16. For now record the result and move on.

- [ ] **Step 5: Commit any sdkconfig fragment changes**

If you needed to create `sdkconfigs/cores3`, commit it in `bash0C7/R2P2-ESP32`:

```bash
cd /Users/bash/dev/src/github.com/bash0C7/R2P2-ESP32 && git checkout -b feature/cores3-stackchan && git add sdkconfigs/cores3 && git commit -m "feat(sdkconfigs): CoreS3 fragment for stackchan-picoruby"
```

If no changes were needed, no commit.

- [ ] **Step 6: Halt and report to user**

If REPL booted: report success and proceed. If not: stop the plan, capture the failure mode, and re-evaluate Task 4 strategy.

---

## Phase C: picoruby-ili9342 mrbgem skeleton

### Task 5: Create mrbgem skeleton

**Files:**
- Create: `mrbgems/picoruby-ili9342/mrbgem.rake`
- Create: `mrbgems/picoruby-ili9342/Gemfile`
- Create: `mrbgems/picoruby-ili9342/Rakefile`
- Create: `mrbgems/picoruby-ili9342/LICENSE`
- Create: `mrbgems/picoruby-ili9342/README.md`
- Create: `mrbgems/picoruby-ili9342/.gitignore`
- Create: `mrbgems/picoruby-ili9342/mrblib/ili9342.rb` (empty stub class)
- Create: `mrbgems/picoruby-ili9342/sig/ili9342.rbs` (empty)

(All paths below relative to `/Users/bash/dev/src/github.com/m5stack/stackchan-picoruby/`.)

- [ ] **Step 1: Create directory tree**

```bash
cd /Users/bash/dev/src/github.com/m5stack/stackchan-picoruby && mkdir -p mrbgems/picoruby-ili9342/{mrblib,sig,test,examples,docs}
```

- [ ] **Step 2: Write `mrbgem.rake`**

`mrbgems/picoruby-ili9342/mrbgem.rake`:

```ruby
MRuby::Gem::Specification.new('picoruby-ili9342') do |spec|
  spec.license = 'MIT'
  spec.author  = 'bash0C7'
  spec.summary = 'ILI9342 LCD driver - pure Ruby PicoRuby Runtime Gem'

  spec.add_dependency 'picoruby-spi'
  spec.add_dependency 'picoruby-gpio'
  spec.add_dependency 'picoruby-machine'
  spec.add_test_dependency 'picoruby-picotest'
end
```

- [ ] **Step 3: Write `Gemfile`**

`mrbgems/picoruby-ili9342/Gemfile`:

```ruby
source "https://rubygems.org"

gem "rake", "~> 13.0"
gem "test-unit", "~> 3.6"
```

- [ ] **Step 4: Write `Rakefile`**

`mrbgems/picoruby-ili9342/Rakefile`:

```ruby
require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.libs << "mrblib"
  t.test_files = FileList["test/**/*_test.rb"]
  t.verbose = true
end

task default: :test
```

- [ ] **Step 5: Write `LICENSE` (MIT)**

`mrbgems/picoruby-ili9342/LICENSE`:

```
MIT License

Copyright (c) 2026 bash0C7

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

- [ ] **Step 6: Write `.gitignore`**

`mrbgems/picoruby-ili9342/.gitignore`:

```
Gemfile.lock
/tmp/
*.swp
.bundle/
```

- [ ] **Step 7: Write minimal `README.md`**

`mrbgems/picoruby-ili9342/README.md`:

```markdown
# picoruby-ili9342

ILI9342 LCD controller driver for PicoRuby. Pure Ruby implementation on top of `picoruby-spi` and `picoruby-gpio`.

## Status

Work in progress. Initial target: M5Stack CoreS3 (320×240, landscape).

## Usage

```ruby
require 'spi'
require 'gpio'
require 'ili9342'

spi = SPI.new(unit: :ESP32_SPI2_HOST, frequency: 40_000_000,
              sck_pin: <SCK>, copi_pin: <MOSI>, cs_pin: <CS>, mode: 0)
display = ILI9342.new(
  spi: spi, dc_pin: <DC>, cs_pin: <CS>, rst_pin: <RST>, bl_pin: <BL>,
  width: 320, height: 240, rotation: :landscape
)

display.fill(ILI9342::Color::BLACK)
display.draw_rect(10, 10, 50, 30, ILI9342::Color::GREEN, fill: true)
```

Replace `<SCK>` etc. with concrete CoreS3 pin numbers from `docs/cores3-pinout-and-init.md`.

## Examples

See `examples/` for `black_fill.rb`, `color_cycle.rb`, `face_neutral.rb`, `face_smile.rb`, `face_joy.rb`, `avatar_demo.rb`.
```

- [ ] **Step 8: Write empty class stub**

`mrbgems/picoruby-ili9342/mrblib/ili9342.rb`:

```ruby
require 'spi'
require 'gpio'

class ILI9342
end
```

- [ ] **Step 9: Write empty rbs**

`mrbgems/picoruby-ili9342/sig/ili9342.rbs`:

```rbs
class ILI9342
end
```

- [ ] **Step 10: Install gems and verify rake runs**

```bash
cd /Users/bash/dev/src/github.com/m5stack/stackchan-picoruby/mrbgems/picoruby-ili9342 && bundle install
```

Expected: bundle resolves and installs.

- [ ] **Step 11: Commit skeleton**

```bash
cd /Users/bash/dev/src/github.com/m5stack/stackchan-picoruby && git add mrbgems/picoruby-ili9342 && git commit -m "feat(ili9342): mrbgem skeleton with empty class stub"
```

---

### Task 6: Test infrastructure (mocks + shims)

**Files:**
- Create: `mrbgems/picoruby-ili9342/test/test_helper.rb`
- Create: `mrbgems/picoruby-ili9342/test/spi_mock.rb`
- Create: `mrbgems/picoruby-ili9342/test/gpio_mock.rb`
- Create: `mrbgems/picoruby-ili9342/test/ili9342_test.rb`

- [ ] **Step 1: Write `test/spi_mock.rb`**

```ruby
class FakeSPI
  attr_reader :writes

  def initialize
    @writes = []
  end

  def write(*data)
    @writes.concat(data.flat_map { |d| coerce(d) })
    data.size
  end

  def select
    yield self
    deselect
  end

  def deselect
    @writes << :deselect
  end

  def transfer(*data, additional_read_bytes: 0)
    @writes.concat(data.flat_map { |d| coerce(d) })
    "\x00".b * (data.size + additional_read_bytes)
  end

  def read(length, _repeated_tx_data = 0)
    "\x00".b * length
  end

  def reset_log!
    @writes = []
  end

  private

  def coerce(d)
    case d
    when Integer then [d & 0xFF]
    when String  then d.bytes
    when Array   then d.flat_map { |x| coerce(x) }
    else
      raise ArgumentError, "FakeSPI cannot coerce #{d.class}"
    end
  end
end
```

- [ ] **Step 2: Write `test/gpio_mock.rb`**

```ruby
class FakeGPIO
  attr_reader :pin, :history
  attr_accessor :value

  IN  = :in
  OUT = :out
  HIGH = 1
  LOW  = 0

  def initialize(pin, dir = OUT)
    @pin = pin
    @dir = dir
    @value = 0
    @history = []
  end

  def write(v)
    @value = v
    @history << [:write, v]
  end

  def read
    @value
  end

  def high
    write(1)
  end

  def low
    write(0)
  end
end
```

- [ ] **Step 3: Write `test/test_helper.rb`**

```ruby
$LOAD_PATH.unshift File.expand_path("../mrblib", __dir__)
$LOAD_PATH.unshift File.expand_path(".", __dir__)

# PicoRuby shim: 'spi' / 'gpio' are runtime built-ins; no-op the require under CRuby.
$LOADED_FEATURES << "spi"  unless $LOADED_FEATURES.include?("spi")
$LOADED_FEATURES << "gpio" unless $LOADED_FEATURES.include?("gpio")

# PicoRuby shim: Machine.delay_ms is a runtime built-in.
unless defined?(Machine)
  module Machine
    def self.delay_ms(_ms); end
    def self.uptime_us; 0; end
  end
end

# PicoRuby shim: SPI/GPIO classes are runtime built-ins. We don't need real
# ones in host tests, only the FakeSPI/FakeGPIO doubles that callers inject.
class SPI;  end unless defined?(SPI)
class GPIO; end unless defined?(GPIO)

require "test/unit"
require "spi_mock"
require "gpio_mock"
```

- [ ] **Step 4: Write empty `test/ili9342_test.rb`**

```ruby
require "test_helper"
require "ili9342"

class HarnessTest < Test::Unit::TestCase
  def test_fake_spi_records_writes
    spi = FakeSPI.new
    spi.write(0xAB, 0xCD)
    assert_equal [0xAB, 0xCD], spi.writes
  end

  def test_fake_gpio_records_history
    gpio = FakeGPIO.new(17)
    gpio.high
    gpio.low
    assert_equal [[:write, 1], [:write, 0]], gpio.history
  end
end
```

- [ ] **Step 5: Run tests (delegate to subagent)**

Dispatch a `general-purpose` subagent: "run `cd /Users/bash/dev/src/github.com/m5stack/stackchan-picoruby/mrbgems/picoruby-ili9342 && bundle exec rake test` and report only pass/fail and total test count."

Expected: 2 tests pass, 0 failures, 0 errors.

- [ ] **Step 6: Commit infrastructure**

```bash
cd /Users/bash/dev/src/github.com/m5stack/stackchan-picoruby && git add mrbgems/picoruby-ili9342/test && git commit -m "test(ili9342): test harness with FakeSPI/FakeGPIO doubles and PicoRuby shims"
```

---

## Phase D: TDD implementation of ILI9342 driver

Each task in Phase D follows RED → GREEN → REFACTOR commit cadence per project TDD discipline. Subagent test runs only return pass/fail counts.

### Task 7: Initialization sequence

**Files:**
- Modify: `mrbgems/picoruby-ili9342/test/ili9342_test.rb`
- Modify: `mrbgems/picoruby-ili9342/mrblib/ili9342.rb`

- [ ] **Step 1: Append failing test for init sequence**

Append to `test/ili9342_test.rb`:

```ruby
class ILI9342InitTest < Test::Unit::TestCase
  def setup
    @spi = FakeSPI.new
    @dc  = FakeGPIO.new(2)
    @cs  = FakeGPIO.new(3)
    @rst = FakeGPIO.new(4)
    @bl  = FakeGPIO.new(5)
    @display = ILI9342.new(spi: @spi, dc_pin: @dc, cs_pin: @cs,
                           rst_pin: @rst, bl_pin: @bl,
                           width: 320, height: 240, rotation: :landscape)
  end

  def test_reset_pin_pulsed
    history = @rst.history.map(&:last)
    assert_equal [1, 0, 1], history.first(3),
                 "RST should go high → low → high during init"
  end

  def test_dc_low_for_command_then_high_for_data
    # First command (SLPOUT or SWRESET) should set DC low before SPI write,
    # then DC high before payload bytes (if any).
    assert @dc.history.size >= 2,
           "DC pin should toggle multiple times during init"
    assert_equal 0, @dc.history.first.last,
                 "First DC level must be LOW (command)"
  end

  def test_init_sends_disp_on
    bytes = @spi.writes.select { |b| b.is_a?(Integer) }
    assert_includes bytes, 0x29, "DISPON (0x29) must be sent during init"
  end

  def test_init_sends_madctl_for_landscape
    bytes = @spi.writes.select { |b| b.is_a?(Integer) }
    idx = bytes.index(0x36)
    assert idx, "MADCTL (0x36) must be sent during init"
    landscape_madctl = ILI9342::MADCTL_LANDSCAPE
    assert_equal landscape_madctl, bytes[idx + 1],
                 "Landscape MADCTL value must follow 0x36 command"
  end
end
```

- [ ] **Step 2: Run, verify fail**

Subagent: `bundle exec rake test`. Expected: 4 new failures (NameError on `ILI9342.new`, missing constants).

- [ ] **Step 3: RED commit**

```bash
git add mrbgems/picoruby-ili9342/test/ili9342_test.rb && git commit -m "test(ili9342): add failing init sequence specs"
```

- [ ] **Step 4: Implement init in `mrblib/ili9342.rb`**

Replace `mrblib/ili9342.rb` with:

```ruby
require 'spi'
require 'gpio'

class ILI9342
  # MADCTL bits: MY|MX|MV|ML|RGB|MH|0|0
  MADCTL_PORTRAIT       = 0x08  # row=0, col=0, BGR
  MADCTL_LANDSCAPE      = 0x68  # row=1, col=1, swap, BGR
  MADCTL_PORTRAIT_FLIP  = 0xC8
  MADCTL_LANDSCAPE_FLIP = 0xA8

  # Commands
  CMD_SWRESET = 0x01
  CMD_SLPOUT  = 0x11
  CMD_DISPON  = 0x29
  CMD_CASET   = 0x2A
  CMD_RASET   = 0x2B
  CMD_RAMWR   = 0x2C
  CMD_MADCTL  = 0x36
  CMD_COLMOD  = 0x3A

  # Replace this list with the verified sequence transcribed in Task 3
  # from docs/cores3-pinout-and-init.md.
  INIT_COMMANDS = [
    [CMD_SWRESET, [],     120],
    [CMD_SLPOUT,  [],     120],
    [CMD_COLMOD,  [0x55],   0],   # 16-bit/pixel
    [CMD_DISPON,  [],     100],
  ].freeze

  def initialize(spi:, dc_pin:, cs_pin:, rst_pin:, bl_pin:, width:, height:, rotation: :landscape)
    @spi    = spi
    @dc     = dc_pin
    @cs     = cs_pin
    @rst    = rst_pin
    @bl     = bl_pin
    @width  = width
    @height = height
    @rotation = rotation

    hardware_reset
    send_init_sequence
    set_rotation(rotation)
    set_backlight(true)
  end

  attr_reader :width, :height, :rotation

  def set_backlight(on)
    @bl.write(on ? 1 : 0)
  end

  def set_rotation(sym)
    val = case sym
          when :portrait        then MADCTL_PORTRAIT
          when :landscape       then MADCTL_LANDSCAPE
          when :portrait_flip   then MADCTL_PORTRAIT_FLIP
          when :landscape_flip  then MADCTL_LANDSCAPE_FLIP
          else raise ArgumentError, "rotation must be one of :portrait, :landscape, :portrait_flip, :landscape_flip"
          end
    write_command(CMD_MADCTL, [val])
    @rotation = sym
  end

  private

  def hardware_reset
    @rst.write(1)
    Machine.delay_ms(5)
    @rst.write(0)
    Machine.delay_ms(20)
    @rst.write(1)
    Machine.delay_ms(120)
  end

  def send_init_sequence
    INIT_COMMANDS.each do |cmd, payload, delay_ms|
      write_command(cmd, payload)
      Machine.delay_ms(delay_ms) if delay_ms > 0
    end
  end

  def write_command(cmd, payload = [])
    @cs.write(0)
    @dc.write(0)
    @spi.write(cmd & 0xFF)
    if payload && !payload.empty?
      @dc.write(1)
      @spi.write(*payload)
    end
    @cs.write(1)
  end
end
```

- [ ] **Step 5: Run tests, verify pass**

Subagent. Expected: all init-sequence tests pass.

- [ ] **Step 6: GREEN commit**

```bash
git add mrbgems/picoruby-ili9342 && git commit -m "feat(ili9342): hardware reset + minimal init sequence + rotation MADCTL"
```

- [ ] **Step 7: REFACTOR — replace placeholder INIT_COMMANDS with verified sequence from `docs/cores3-pinout-and-init.md`**

Open `mrbgems/picoruby-ili9342/docs/cores3-pinout-and-init.md` (created in Task 3). Replace the `INIT_COMMANDS` constant in `mrblib/ili9342.rb` with the transcribed sequence.

- [ ] **Step 8: Re-run tests, verify still green**

Subagent. Expected: all tests still pass (init bytes changed but DISPON / MADCTL still in sequence).

- [ ] **Step 9: REFACTOR commit**

```bash
git add mrbgems/picoruby-ili9342/mrblib/ili9342.rb && git commit -m "refactor(ili9342): replace placeholder init with verified CoreS3 sequence"
```

---

### Task 8: RGB565 helper + Color constants

**Files:**
- Modify: `mrbgems/picoruby-ili9342/test/ili9342_test.rb`
- Modify: `mrbgems/picoruby-ili9342/mrblib/ili9342.rb`

- [ ] **Step 1: Append failing tests**

```ruby
class ILI9342ColorTest < Test::Unit::TestCase
  def test_color_constants
    assert_equal 0x0000, ILI9342::Color::BLACK
    assert_equal 0xFFFF, ILI9342::Color::WHITE
    assert_equal 0xF800, ILI9342::Color::RED
    assert_equal 0x07E0, ILI9342::Color::GREEN
    assert_equal 0x001F, ILI9342::Color::BLUE
  end

  def test_rgb_helper
    assert_equal 0x0000, ILI9342.rgb(0, 0, 0)
    assert_equal 0xFFFF, ILI9342.rgb(255, 255, 255)
    assert_equal 0xF800, ILI9342.rgb(255, 0, 0)
    assert_equal 0x07E0, ILI9342.rgb(0, 255, 0)
    assert_equal 0x001F, ILI9342.rgb(0, 0, 255)
  end
end
```

- [ ] **Step 2: Run, verify fail**

Subagent. Expected: NameError on `ILI9342::Color`.

- [ ] **Step 3: RED commit**

```bash
git add . && git commit -m "test(ili9342): add failing RGB565 color helper specs"
```

- [ ] **Step 4: Implement Color module + rgb helper**

Insert near the top of `class ILI9342`, after the constants:

```ruby
  module Color
    BLACK = 0x0000
    WHITE = 0xFFFF
    RED   = 0xF800
    GREEN = 0x07E0
    BLUE  = 0x001F
  end

  def self.rgb(r, g, b)
    ((r & 0xF8) << 8) | ((g & 0xFC) << 3) | ((b & 0xF8) >> 3)
  end
```

- [ ] **Step 5: Run, verify pass**

Subagent.

- [ ] **Step 6: GREEN commit**

```bash
git add mrbgems/picoruby-ili9342/mrblib/ili9342.rb && git commit -m "feat(ili9342): RGB565 color constants and rgb() helper"
```

---

### Task 9: `fill`

**Files:**
- Modify: `mrbgems/picoruby-ili9342/test/ili9342_test.rb`
- Modify: `mrbgems/picoruby-ili9342/mrblib/ili9342.rb`

- [ ] **Step 1: Append failing test**

```ruby
class ILI9342FillTest < Test::Unit::TestCase
  def setup
    @spi = FakeSPI.new
    @display = ILI9342.new(spi: @spi, dc_pin: FakeGPIO.new(2), cs_pin: FakeGPIO.new(3),
                           rst_pin: FakeGPIO.new(4), bl_pin: FakeGPIO.new(5),
                           width: 320, height: 240)
    @spi.reset_log!
  end

  def test_fill_writes_caset_raset_ramwr_then_pixel_payload
    @display.fill(ILI9342::Color::RED)
    bytes = @spi.writes.select { |b| b.is_a?(Integer) }

    assert_includes bytes, ILI9342::CMD_CASET, "CASET must be issued before fill"
    assert_includes bytes, ILI9342::CMD_RASET, "RASET must be issued before fill"
    assert_includes bytes, ILI9342::CMD_RAMWR, "RAMWR must be issued before pixel payload"
  end

  def test_fill_writes_correct_pixel_count
    @display.fill(ILI9342::Color::BLUE)
    bytes = @spi.writes.select { |b| b.is_a?(Integer) }
    ramwr_idx = bytes.index(ILI9342::CMD_RAMWR)
    payload   = bytes[(ramwr_idx + 1)..-1]
    expected_payload_bytes = 320 * 240 * 2
    assert_equal expected_payload_bytes, payload.size,
                 "320*240*2 bytes of pixel data must follow RAMWR"
  end
end
```

- [ ] **Step 2: Run, verify fail**

- [ ] **Step 3: RED commit**

```bash
git add mrbgems/picoruby-ili9342/test/ili9342_test.rb && git commit -m "test(ili9342): add failing fill() spec"
```

- [ ] **Step 4: Implement `fill` and helpers `set_window`, `write_pixels`**

Add these private methods (and make `fill` public):

```ruby
  def fill(rgb565)
    set_window(0, 0, @width - 1, @height - 1)
    write_command(CMD_RAMWR)
    hi = (rgb565 >> 8) & 0xFF
    lo = rgb565 & 0xFF
    chunk = ([hi, lo] * 256)  # 512 bytes per chunk to keep SPI buffer manageable
    @cs.write(0)
    @dc.write(1)
    full_chunks, leftover_pairs = (@width * @height).divmod(256)
    full_chunks.times { @spi.write(*chunk) }
    @spi.write(*([hi, lo] * leftover_pairs)) if leftover_pairs > 0
    @cs.write(1)
  end

  private

  def set_window(x0, y0, x1, y1)
    write_command(CMD_CASET, [(x0 >> 8) & 0xFF, x0 & 0xFF, (x1 >> 8) & 0xFF, x1 & 0xFF])
    write_command(CMD_RASET, [(y0 >> 8) & 0xFF, y0 & 0xFF, (y1 >> 8) & 0xFF, y1 & 0xFF])
  end
```

- [ ] **Step 5: Run, verify pass**

- [ ] **Step 6: GREEN commit**

```bash
git add mrbgems/picoruby-ili9342/mrblib/ili9342.rb && git commit -m "feat(ili9342): fill() with chunked RGB565 RAMWR payload"
```

---

### Task 10: `draw_pixel`

**Files:**
- Modify: `mrbgems/picoruby-ili9342/test/ili9342_test.rb`
- Modify: `mrbgems/picoruby-ili9342/mrblib/ili9342.rb`

- [ ] **Step 1: Append failing tests**

```ruby
class ILI9342DrawPixelTest < Test::Unit::TestCase
  def setup
    @spi = FakeSPI.new
    @display = ILI9342.new(spi: @spi, dc_pin: FakeGPIO.new(2), cs_pin: FakeGPIO.new(3),
                           rst_pin: FakeGPIO.new(4), bl_pin: FakeGPIO.new(5),
                           width: 320, height: 240)
    @spi.reset_log!
  end

  def test_draw_pixel_sets_window_to_one_pixel_and_writes_two_bytes
    @display.draw_pixel(100, 50, 0xABCD)
    bytes = @spi.writes.select { |b| b.is_a?(Integer) }

    caset_idx = bytes.index(ILI9342::CMD_CASET)
    raset_idx = bytes.index(ILI9342::CMD_RASET)
    ramwr_idx = bytes.index(ILI9342::CMD_RAMWR)

    assert caset_idx, "CASET expected"
    assert_equal [0x00, 0x64, 0x00, 0x64], bytes[caset_idx + 1, 4],
                 "CASET payload must encode x=100..100"
    assert_equal [0x00, 0x32, 0x00, 0x32], bytes[raset_idx + 1, 4],
                 "RASET payload must encode y=50..50"
    payload = bytes[(ramwr_idx + 1)..-1]
    assert_equal [0xAB, 0xCD], payload, "single pixel must be 2 bytes"
  end

  def test_draw_pixel_clips_out_of_range
    @display.draw_pixel(-1, 50, 0xFFFF)
    @display.draw_pixel(320, 50, 0xFFFF)
    @display.draw_pixel(100, -1, 0xFFFF)
    @display.draw_pixel(100, 240, 0xFFFF)
    bytes = @spi.writes.select { |b| b.is_a?(Integer) }
    assert_equal 0, bytes.count(ILI9342::CMD_RAMWR),
                 "out-of-range coords must not write any pixel"
  end
end
```

- [ ] **Step 2 & 3: Run (RED) + commit**

```bash
git add mrbgems/picoruby-ili9342/test/ili9342_test.rb && git commit -m "test(ili9342): add failing draw_pixel specs (window + clipping)"
```

- [ ] **Step 4: Implement `draw_pixel`**

```ruby
  def draw_pixel(x, y, rgb565)
    return if x < 0 || x >= @width || y < 0 || y >= @height
    set_window(x, y, x, y)
    write_command(CMD_RAMWR)
    @cs.write(0)
    @dc.write(1)
    @spi.write((rgb565 >> 8) & 0xFF, rgb565 & 0xFF)
    @cs.write(1)
  end
```

- [ ] **Step 5 & 6: Run + GREEN commit**

```bash
git add mrbgems/picoruby-ili9342/mrblib/ili9342.rb && git commit -m "feat(ili9342): draw_pixel with bounds clipping"
```

---

### Task 11: `draw_rect`

**Files:**
- Modify: `mrbgems/picoruby-ili9342/test/ili9342_test.rb`
- Modify: `mrbgems/picoruby-ili9342/mrblib/ili9342.rb`

- [ ] **Step 1: Append failing test**

```ruby
class ILI9342DrawRectTest < Test::Unit::TestCase
  def setup
    @spi = FakeSPI.new
    @display = ILI9342.new(spi: @spi, dc_pin: FakeGPIO.new(2), cs_pin: FakeGPIO.new(3),
                           rst_pin: FakeGPIO.new(4), bl_pin: FakeGPIO.new(5),
                           width: 320, height: 240)
    @spi.reset_log!
  end

  def test_draw_rect_fill_writes_w_times_h_pixels
    @display.draw_rect(10, 10, 5, 4, 0x1234, fill: true)
    bytes = @spi.writes.select { |b| b.is_a?(Integer) }
    ramwr_idx = bytes.index(ILI9342::CMD_RAMWR)
    payload = bytes[(ramwr_idx + 1)..-1]
    assert_equal 5 * 4 * 2, payload.size, "fill rect must write w*h*2 bytes"
  end

  def test_draw_rect_outline_uses_four_lines
    # outline = top + bottom + left + right edges, each w or h pixels
    @display.draw_rect(0, 0, 10, 5, 0xFFFF, fill: false)
    ramwr_count = @spi.writes.count(ILI9342::CMD_RAMWR)
    # four edges = up to 4 RAMWR sessions (or fewer if optimized into a single window)
    assert ramwr_count >= 1, "outline must produce at least one RAMWR"
  end
end
```

- [ ] **Step 2 & 3: RED commit**

```bash
git add mrbgems/picoruby-ili9342/test/ili9342_test.rb && git commit -m "test(ili9342): add failing draw_rect specs (fill + outline)"
```

- [ ] **Step 4: Implement**

```ruby
  def draw_rect(x, y, w, h, rgb565, fill: false)
    return if w <= 0 || h <= 0
    x0 = [x, 0].max
    y0 = [y, 0].max
    x1 = [x + w - 1, @width - 1].min
    y1 = [y + h - 1, @height - 1].min
    return if x0 > x1 || y0 > y1

    if fill
      set_window(x0, y0, x1, y1)
      write_command(CMD_RAMWR)
      hi = (rgb565 >> 8) & 0xFF
      lo = rgb565 & 0xFF
      count = (x1 - x0 + 1) * (y1 - y0 + 1)
      @cs.write(0)
      @dc.write(1)
      count.times { @spi.write(hi, lo) }
      @cs.write(1)
    else
      draw_line(x0, y0, x1, y0, rgb565)
      draw_line(x0, y1, x1, y1, rgb565)
      draw_line(x0, y0, x0, y1, rgb565)
      draw_line(x1, y0, x1, y1, rgb565)
    end
  end
```

(`draw_line` is the next task; for now leave outline tests passing trivially via filled-rect fallback if needed. The outline test only asserts ≥1 RAMWR, so `draw_line` can be stubbed as `draw_pixel` per endpoint pair temporarily — replace with Bresenham in Task 12.)

For the outline branch to satisfy step 1 immediately, add a temporary stub:

```ruby
  def draw_line(x0, y0, x1, y1, rgb565)
    draw_pixel(x0, y0, rgb565)
    draw_pixel(x1, y1, rgb565)
  end
```

We'll replace `draw_line` properly in Task 12.

- [ ] **Step 5 & 6: GREEN commit**

```bash
git add mrbgems/picoruby-ili9342/mrblib/ili9342.rb && git commit -m "feat(ili9342): draw_rect with fill/outline (line stubbed)"
```

---

### Task 12: `draw_line` (Bresenham)

**Files:**
- Modify: `mrbgems/picoruby-ili9342/test/ili9342_test.rb`
- Modify: `mrbgems/picoruby-ili9342/mrblib/ili9342.rb`

- [ ] **Step 1: Append failing tests**

```ruby
class ILI9342DrawLineTest < Test::Unit::TestCase
  def setup
    @spi = FakeSPI.new
    @display = ILI9342.new(spi: @spi, dc_pin: FakeGPIO.new(2), cs_pin: FakeGPIO.new(3),
                           rst_pin: FakeGPIO.new(4), bl_pin: FakeGPIO.new(5),
                           width: 320, height: 240)
    @spi.reset_log!
  end

  def test_horizontal_line_writes_n_pixels
    # 10 pixels from (5, 5) to (14, 5)
    @display.draw_line(5, 5, 14, 5, 0xFFFF)
    bytes = @spi.writes.select { |b| b.is_a?(Integer) }
    pixel_writes = bytes.count(ILI9342::CMD_RAMWR)
    assert_equal 10, pixel_writes, "horizontal 10-px line must trigger 10 single-pixel writes"
  end

  def test_vertical_line_writes_n_pixels
    @display.draw_line(20, 0, 20, 4, 0xF800)
    bytes = @spi.writes.select { |b| b.is_a?(Integer) }
    assert_equal 5, bytes.count(ILI9342::CMD_RAMWR)
  end

  def test_diagonal_line_writes_n_pixels
    @display.draw_line(0, 0, 4, 4, 0x07E0)
    bytes = @spi.writes.select { |b| b.is_a?(Integer) }
    assert_equal 5, bytes.count(ILI9342::CMD_RAMWR)
  end
end
```

- [ ] **Step 2 & 3: RED commit**

The earlier stub from Task 11 will fail these (it only writes 2 endpoints).

```bash
git add mrbgems/picoruby-ili9342/test/ili9342_test.rb && git commit -m "test(ili9342): add failing draw_line Bresenham specs"
```

- [ ] **Step 4: Replace stub with Bresenham**

```ruby
  def draw_line(x0, y0, x1, y1, rgb565)
    dx = (x1 - x0).abs
    dy = -(y1 - y0).abs
    sx = x0 < x1 ? 1 : -1
    sy = y0 < y1 ? 1 : -1
    err = dx + dy
    x = x0
    y = y0
    loop do
      draw_pixel(x, y, rgb565)
      break if x == x1 && y == y1
      e2 = err * 2
      if e2 >= dy
        err += dy
        x += sx
      end
      if e2 <= dx
        err += dx
        y += sy
      end
    end
  end
```

- [ ] **Step 5 & 6: GREEN commit**

```bash
git add mrbgems/picoruby-ili9342/mrblib/ili9342.rb && git commit -m "feat(ili9342): draw_line via Bresenham"
```

---

### Task 13: `draw_ellipse` (midpoint algorithm)

**Files:**
- Modify: `mrbgems/picoruby-ili9342/test/ili9342_test.rb`
- Modify: `mrbgems/picoruby-ili9342/mrblib/ili9342.rb`

- [ ] **Step 1: Append failing tests**

```ruby
class ILI9342DrawEllipseTest < Test::Unit::TestCase
  def setup
    @spi = FakeSPI.new
    @display = ILI9342.new(spi: @spi, dc_pin: FakeGPIO.new(2), cs_pin: FakeGPIO.new(3),
                           rst_pin: FakeGPIO.new(4), bl_pin: FakeGPIO.new(5),
                           width: 320, height: 240)
    @spi.reset_log!
  end

  def test_outline_ellipse_writes_at_least_perimeter_pixels
    @display.draw_ellipse(50, 50, 10, 5, 0xFFFF, fill: false)
    pixel_count = @spi.writes.count(ILI9342::CMD_RAMWR)
    # Rough estimate: perimeter ~= 2*pi*sqrt((rx^2 + ry^2)/2) ≈ 50
    assert pixel_count >= 24, "outline must write at least 24 pixels for r=10/5"
    assert pixel_count <= 80, "and not more than 80"
  end

  def test_filled_ellipse_writes_more_pixels_than_outline
    @display.draw_ellipse(50, 50, 10, 5, 0xFFFF, fill: false)
    outline_count = @spi.writes.count(ILI9342::CMD_RAMWR)
    @spi.reset_log!
    @display.draw_ellipse(50, 50, 10, 5, 0xFFFF, fill: true)
    fill_count = @spi.writes.count(ILI9342::CMD_RAMWR)
    assert fill_count > outline_count, "filled ellipse must write more pixels than outline"
  end
end
```

- [ ] **Step 2 & 3: RED commit**

```bash
git add mrbgems/picoruby-ili9342/test/ili9342_test.rb && git commit -m "test(ili9342): add failing draw_ellipse specs (outline + fill)"
```

- [ ] **Step 4: Implement midpoint ellipse**

```ruby
  def draw_ellipse(cx, cy, rx, ry, rgb565, fill: false)
    return if rx <= 0 || ry <= 0
    plot = lambda do |dx, dy|
      if fill
        draw_line(cx - dx, cy + dy, cx + dx, cy + dy, rgb565)
        draw_line(cx - dx, cy - dy, cx + dx, cy - dy, rgb565)
      else
        draw_pixel(cx + dx, cy + dy, rgb565)
        draw_pixel(cx - dx, cy + dy, rgb565)
        draw_pixel(cx + dx, cy - dy, rgb565)
        draw_pixel(cx - dx, cy - dy, rgb565)
      end
    end

    rx2 = rx * rx
    ry2 = ry * ry
    two_rx2 = 2 * rx2
    two_ry2 = 2 * ry2

    # Region 1
    x = 0
    y = ry
    px = 0
    py = two_rx2 * y
    p = (ry2 - rx2 * ry + rx2 / 4.0).round
    plot.call(x, y)
    while px < py
      x += 1
      px += two_ry2
      if p < 0
        p += ry2 + px
      else
        y -= 1
        py -= two_rx2
        p += ry2 + px - py
      end
      plot.call(x, y)
    end

    # Region 2
    p = (ry2 * (x + 0.5)**2 + rx2 * (y - 1)**2 - rx2 * ry2).round
    while y > 0
      y -= 1
      py -= two_rx2
      if p > 0
        p += rx2 - py
      else
        x += 1
        px += two_ry2
        p += rx2 - py + px
      end
      plot.call(x, y)
    end
  end
```

- [ ] **Step 5 & 6: GREEN commit**

```bash
git add mrbgems/picoruby-ili9342/mrblib/ili9342.rb && git commit -m "feat(ili9342): draw_ellipse via midpoint algorithm (outline + fill)"
```

---

### Task 14: Update `sig/ili9342.rbs`

**Files:**
- Modify: `mrbgems/picoruby-ili9342/sig/ili9342.rbs`

- [ ] **Step 1: Replace with full type signatures**

```rbs
class ILI9342
  type rotation_t = :portrait | :landscape | :portrait_flip | :landscape_flip

  MADCTL_PORTRAIT: Integer
  MADCTL_LANDSCAPE: Integer
  MADCTL_PORTRAIT_FLIP: Integer
  MADCTL_LANDSCAPE_FLIP: Integer

  CMD_SWRESET: Integer
  CMD_SLPOUT: Integer
  CMD_DISPON: Integer
  CMD_CASET: Integer
  CMD_RASET: Integer
  CMD_RAMWR: Integer
  CMD_MADCTL: Integer
  CMD_COLMOD: Integer

  module Color
    BLACK: Integer
    WHITE: Integer
    RED:   Integer
    GREEN: Integer
    BLUE:  Integer
  end

  attr_reader width: Integer
  attr_reader height: Integer
  attr_reader rotation: rotation_t

  def self.rgb: (Integer, Integer, Integer) -> Integer

  def initialize: (spi: untyped, dc_pin: untyped, cs_pin: untyped, rst_pin: untyped, bl_pin: untyped,
                   width: Integer, height: Integer, ?rotation: rotation_t) -> void

  def fill: (Integer rgb565) -> void
  def draw_pixel: (Integer x, Integer y, Integer rgb565) -> void
  def draw_rect:  (Integer x, Integer y, Integer w, Integer h, Integer rgb565, ?fill: bool) -> void
  def draw_line:  (Integer x0, Integer y0, Integer x1, Integer y1, Integer rgb565) -> void
  def draw_ellipse: (Integer cx, Integer cy, Integer rx, Integer ry, Integer rgb565, ?fill: bool) -> void
  def set_backlight: (bool) -> void
  def set_rotation: (rotation_t) -> void
end
```

- [ ] **Step 2: Commit**

```bash
git add mrbgems/picoruby-ili9342/sig/ili9342.rbs && git commit -m "docs(ili9342): RBS signatures for public API"
```

---

## Phase E: Build integration

### Task 15: Wire `picoruby-ili9342` into bash0C7/R2P2-ESP32 build_config

**Files:**
- Modify: `/Users/bash/dev/src/github.com/bash0C7/R2P2-ESP32/components/picoruby-esp32/build_config/xtensa-esp-picoruby.rb`
- Modify: `/Users/bash/dev/src/github.com/bash0C7/R2P2-ESP32/components/picoruby-esp32/build_config/xtensa-esp-femtoruby.rb` (only if mruby/c VM also targeted)

- [ ] **Step 1: Inspect the existing gembox file**

```bash
cat /Users/bash/dev/src/github.com/bash0C7/R2P2-ESP32/components/picoruby-esp32/build_config/xtensa-esp-picoruby.rb
```

Identify where peripheral gems (`gpio`, `spi`, etc.) are added, e.g. via `conf.gem :core => 'picoruby-spi'` or `conf.gem :path => '...'`.

- [ ] **Step 2: Add path-based gem reference for picoruby-ili9342**

After the `picoruby-spi` line, add:

```ruby
conf.gem path: '/Users/bash/dev/src/github.com/m5stack/stackchan-picoruby/mrbgems/picoruby-ili9342'
```

(Adjust syntax to match existing `conf.gem` pattern in the file. If the file uses `gembox` style instead of `conf.gem`, append to the gembox.)

- [ ] **Step 3: Build R2P2-ESP32 with the new gem**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/R2P2-ESP32 && rake build
```

Expected: build succeeds. If a Pure-Ruby gem fails to compile because of missing C sources, it indicates `mrbgem.rake` is malformed — fix and retry.

- [ ] **Step 4: Commit on a feature branch in bash0C7/R2P2-ESP32**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/R2P2-ESP32 && git add components/picoruby-esp32/build_config/xtensa-esp-picoruby.rb && git commit -m "feat: include picoruby-ili9342 from stackchan-picoruby monorepo"
```

(If a `feature/cores3-stackchan` branch was already started in Task 4, use that branch.)

---

### Task 16: 🔌 HARDWARE — flash with ili9342 + smoke-test require

- [ ] **Step 1: Flash the new build to CoreS3**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/R2P2-ESP32 && rake flash
```

- [ ] **Step 2: Open monitor, smoke-test require**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/R2P2-ESP32 && rake monitor
```

In REPL:

```ruby
> require 'ili9342'
=> true
> ILI9342::CMD_DISPON
=> 41
> ILI9342::Color::RED
=> 63488
```

Expected: each line returns the right value. If `require` fails with `LoadError`, the gem path is wrong — fix Task 15 step 2.

- [ ] **Step 3: Try a real Display init**

Read pin numbers from `mrbgems/picoruby-ili9342/docs/cores3-pinout-and-init.md` (Task 3 output) and substitute below:

```ruby
> spi = SPI.new(unit: :ESP32_SPI2_HOST, frequency: 40_000_000, sck_pin: <SCK>, copi_pin: <MOSI>, cs_pin: <CS>, mode: 0)
> dc  = GPIO.new(<DC>, GPIO::OUT)
> cs  = GPIO.new(<CS>, GPIO::OUT)
> rst = GPIO.new(<RST>, GPIO::OUT)
> bl  = GPIO.new(<BL>, GPIO::OUT)
> d   = ILI9342.new(spi: spi, dc_pin: dc, cs_pin: cs, rst_pin: rst, bl_pin: bl, width: 320, height: 240, rotation: :landscape)
=> #<ILI9342:...>
> d.fill(0x0000)
=> nil
```

Expected: `Display` initializes without error, screen turns black after `d.fill(0x0000)`.

If screen stays blank-white or shows garbage, root-cause before continuing — possibilities are wrong pin numbers, wrong MADCTL value, wrong COLMOD, missing init delay. Iterate on `mrblib/ili9342.rb` and re-flash.

- [ ] **Step 4: Stop and report to user**

User confirms screen actually turned black. Stop the plan if not.

---

## Phase F: Examples + face rendering

### Task 17: `examples/black_fill.rb`

**Files:**
- Create: `mrbgems/picoruby-ili9342/examples/black_fill.rb`

- [ ] **Step 1: Write example**

```ruby
# examples/black_fill.rb — fill the screen black, the simplest "it works" demo.
require 'spi'
require 'gpio'
require 'ili9342'

# CoreS3 pin numbers — see docs/cores3-pinout-and-init.md
SCK_PIN  = <SCK>
MOSI_PIN = <MOSI>
CS_PIN   = <CS>
DC_PIN   = <DC>
RST_PIN  = <RST>
BL_PIN   = <BL>

spi = SPI.new(unit: :ESP32_SPI2_HOST, frequency: 40_000_000,
              sck_pin: SCK_PIN, copi_pin: MOSI_PIN, cs_pin: CS_PIN, mode: 0)
display = ILI9342.new(
  spi: spi,
  dc_pin:  GPIO.new(DC_PIN,  GPIO::OUT),
  cs_pin:  GPIO.new(CS_PIN,  GPIO::OUT),
  rst_pin: GPIO.new(RST_PIN, GPIO::OUT),
  bl_pin:  GPIO.new(BL_PIN,  GPIO::OUT),
  width: 320, height: 240, rotation: :landscape
)

display.fill(ILI9342::Color::BLACK)
```

Replace `<SCK>`, `<MOSI>`, etc. with the actual numbers from Task 3.

- [ ] **Step 2: 🔌 HARDWARE — copy example to home and run**

In R2P2 REPL:

```
> picomodem
```

(or use whichever transfer command R2P2 provides — drag-and-drop in some terminal emulators.) Copy `black_fill.rb` to `/home/black_fill.rb`, then:

```ruby
> load '/home/black_fill.rb'
```

Expected: screen turns solid black.

- [ ] **Step 3: Commit**

```bash
cd /Users/bash/dev/src/github.com/m5stack/stackchan-picoruby && git add mrbgems/picoruby-ili9342/examples/black_fill.rb && git commit -m "feat(examples): black_fill smoke example"
```

---

### Task 18: `examples/color_cycle.rb`

**Files:**
- Create: `mrbgems/picoruby-ili9342/examples/color_cycle.rb`

- [ ] **Step 1: Write example**

```ruby
# examples/color_cycle.rb — cycles RED → GREEN → BLUE every 1 second.
require 'spi'
require 'gpio'
require 'ili9342'

# (Same pin constants as black_fill.rb — copy them inline or move to a shared
# helper file in a future refactor. Keeping copies here for run-anywhere.)
SCK_PIN  = <SCK>
MOSI_PIN = <MOSI>
CS_PIN   = <CS>
DC_PIN   = <DC>
RST_PIN  = <RST>
BL_PIN   = <BL>

spi = SPI.new(unit: :ESP32_SPI2_HOST, frequency: 40_000_000,
              sck_pin: SCK_PIN, copi_pin: MOSI_PIN, cs_pin: CS_PIN, mode: 0)
display = ILI9342.new(
  spi: spi,
  dc_pin:  GPIO.new(DC_PIN,  GPIO::OUT),
  cs_pin:  GPIO.new(CS_PIN,  GPIO::OUT),
  rst_pin: GPIO.new(RST_PIN, GPIO::OUT),
  bl_pin:  GPIO.new(BL_PIN,  GPIO::OUT),
  width: 320, height: 240, rotation: :landscape
)

[ILI9342::Color::RED, ILI9342::Color::GREEN, ILI9342::Color::BLUE].each do |color|
  display.fill(color)
  sleep 1
end
```

- [ ] **Step 2: 🔌 HARDWARE — run, verify cycle**

Expected: red → green → blue, 1 second each.

- [ ] **Step 3: Commit**

```bash
git add mrbgems/picoruby-ili9342/examples/color_cycle.rb && git commit -m "feat(examples): color_cycle 3-color demo"
```

---

### Task 19: Face render module + `examples/face_neutral.rb`

**Files:**
- Create: `mrbgems/picoruby-ili9342/examples/_face.rb` (shared draw helpers)
- Create: `mrbgems/picoruby-ili9342/examples/face_neutral.rb`

- [ ] **Step 1: Read upstream face geometry**

Read `/Users/bash/dev/src/github.com/m5stack/StackChan/firmware/main/stackchan/avatar/skins/default/eyes.cpp` and `mouth.cpp`. Record:
- Eye center positions (left, right) in screen coords for landscape 320×240
- Eye radii (rx, ry)
- Mouth center position
- Mouth straight length and curve `delta_y` for smile/joy

Write findings inline into `_face.rb` constants below.

- [ ] **Step 2: Write `_face.rb`**

```ruby
# examples/_face.rb — shared face rendering helpers used by face_*.rb.
# Eye geometry stays constant across expressions; only the mouth's curve_delta changes.

module Face
  # Replace these constants with the values you read from upstream eyes.cpp
  # in Task 19 step 1.
  EYE_LEFT_CX  = 100   # placeholder
  EYE_LEFT_CY  = 110   # placeholder
  EYE_RIGHT_CX = 220   # placeholder
  EYE_RIGHT_CY = 110   # placeholder
  EYE_RX       = 18    # placeholder
  EYE_RY       = 18    # placeholder

  MOUTH_CX           = 160
  MOUTH_CY           = 180
  MOUTH_HALF_WIDTH   = 30   # half-length of mouth in pixels

  EYE_COLOR        = ILI9342::Color::WHITE
  MOUTH_COLOR      = ILI9342::Color::WHITE
  BACKGROUND_COLOR = ILI9342::Color::BLACK

  def self.draw(display, mouth_delta_y)
    display.fill(BACKGROUND_COLOR)
    draw_eyes(display)
    draw_mouth(display, mouth_delta_y)
  end

  def self.draw_eyes(display)
    display.draw_ellipse(EYE_LEFT_CX,  EYE_LEFT_CY,  EYE_RX, EYE_RY, EYE_COLOR, fill: true)
    display.draw_ellipse(EYE_RIGHT_CX, EYE_RIGHT_CY, EYE_RX, EYE_RY, EYE_COLOR, fill: true)
  end

  # `delta_y` lifts the corners above the center: 0 = straight (neutral),
  # small positive = mild smile, larger positive = joy. Renders as two
  # straight segments forming an inverted-V (∧) — simple but readable.
  def self.draw_mouth(display, delta_y)
    cx = MOUTH_CX
    cy = MOUTH_CY
    hw = MOUTH_HALF_WIDTH
    left_x   = cx - hw
    right_x  = cx + hw
    corner_y = cy - delta_y
    display.draw_line(left_x,  corner_y, cx,      cy,       MOUTH_COLOR)
    display.draw_line(cx,      cy,       right_x, corner_y, MOUTH_COLOR)
  end
end
```

- [ ] **Step 3: Write `face_neutral.rb`**

```ruby
# examples/face_neutral.rb — neutral expression: straight mouth.
require 'spi'
require 'gpio'
require 'ili9342'
require_relative '_face'

SCK_PIN  = <SCK>
MOSI_PIN = <MOSI>
CS_PIN   = <CS>
DC_PIN   = <DC>
RST_PIN  = <RST>
BL_PIN   = <BL>

spi = SPI.new(unit: :ESP32_SPI2_HOST, frequency: 40_000_000,
              sck_pin: SCK_PIN, copi_pin: MOSI_PIN, cs_pin: CS_PIN, mode: 0)
display = ILI9342.new(
  spi: spi,
  dc_pin:  GPIO.new(DC_PIN,  GPIO::OUT),
  cs_pin:  GPIO.new(CS_PIN,  GPIO::OUT),
  rst_pin: GPIO.new(RST_PIN, GPIO::OUT),
  bl_pin:  GPIO.new(BL_PIN,  GPIO::OUT),
  width: 320, height: 240, rotation: :landscape
)

Face.draw(display, 0)   # mouth_delta_y = 0 → straight
```

(`require_relative` may not be available in PicoRuby — if `LoadError`, replace with `require '_face'` after copying both to `/home`.)

- [ ] **Step 4: 🔌 HARDWARE — run, verify**

Expected: ｽﾀｯｸﾁｬﾝ顔 with two white eyes and a horizontal mouth on black background.

- [ ] **Step 5: Commit**

```bash
git add mrbgems/picoruby-ili9342/examples/_face.rb mrbgems/picoruby-ili9342/examples/face_neutral.rb && git commit -m "feat(examples): face_neutral with shared _face helper"
```

---

### Task 20: `examples/face_smile.rb` + `examples/face_joy.rb`

**Files:**
- Create: `mrbgems/picoruby-ili9342/examples/face_smile.rb`
- Create: `mrbgems/picoruby-ili9342/examples/face_joy.rb`

- [ ] **Step 1: Write `face_smile.rb`**

Identical to `face_neutral.rb` except the last line:

```ruby
Face.draw(display, 8)   # mild upward curve
```

- [ ] **Step 2: Write `face_joy.rb`**

Identical except:

```ruby
Face.draw(display, 18)  # large upward curve
```

(Tune `8` and `18` to taste once on hardware — `_face.rb` `MOUTH_HALF_WIDTH` is `30`, so `delta_y` of `8` and `18` produce ~15° and ~31° lift respectively. Adjust per visual judgement.)

- [ ] **Step 3: 🔌 HARDWARE — run both, verify**

Expected: progressively upward-curved mouth from neutral → smile → joy.

- [ ] **Step 4: Commit**

```bash
git add mrbgems/picoruby-ili9342/examples/face_smile.rb mrbgems/picoruby-ili9342/examples/face_joy.rb && git commit -m "feat(examples): face_smile and face_joy variants"
```

---

### Task 21: `examples/avatar_demo.rb`

**Files:**
- Create: `mrbgems/picoruby-ili9342/examples/avatar_demo.rb`

- [ ] **Step 1: Write demo**

```ruby
# examples/avatar_demo.rb — cycle 3 expressions every 5 seconds.
require 'spi'
require 'gpio'
require 'ili9342'
require_relative '_face'

SCK_PIN  = <SCK>
MOSI_PIN = <MOSI>
CS_PIN   = <CS>
DC_PIN   = <DC>
RST_PIN  = <RST>
BL_PIN   = <BL>

spi = SPI.new(unit: :ESP32_SPI2_HOST, frequency: 40_000_000,
              sck_pin: SCK_PIN, copi_pin: MOSI_PIN, cs_pin: CS_PIN, mode: 0)
display = ILI9342.new(
  spi: spi,
  dc_pin:  GPIO.new(DC_PIN,  GPIO::OUT),
  cs_pin:  GPIO.new(CS_PIN,  GPIO::OUT),
  rst_pin: GPIO.new(RST_PIN, GPIO::OUT),
  bl_pin:  GPIO.new(BL_PIN,  GPIO::OUT),
  width: 320, height: 240, rotation: :landscape
)

EXPRESSIONS = [
  [:neutral, 0],
  [:smile,   8],
  [:joy,    18],
]

loop do
  EXPRESSIONS.each do |_name, delta|
    Face.draw(display, delta)
    sleep 5
  end
end
```

- [ ] **Step 2: 🔌 HARDWARE — run, verify**

Expected: face cycles neutral → smile → joy → neutral → ... at 5-second intervals indefinitely.

- [ ] **Step 3: Commit**

```bash
git add mrbgems/picoruby-ili9342/examples/avatar_demo.rb && git commit -m "feat(examples): avatar_demo cycles 3 expressions"
```

---

### Task 22: 🔌 HARDWARE — autostart via `home/app.rb`

- [ ] **Step 1: Copy face_neutral to home/app.rb on device**

In R2P2 REPL:
```
> cp /home/face_neutral.rb /home/app.rb
```

(Or use `picomodem` to upload `face_neutral.rb` as `app.rb`.)

- [ ] **Step 2: Reboot CoreS3**

Press the reset button (or `Machine.reboot` from REPL).

- [ ] **Step 3: Verify auto-display**

Expected: within ~5 seconds after reset, neutral face appears on screen without REPL interaction.

If it doesn't, check `app.rb` exists in `/home/` and is parseable; check the reboot didn't enter BOOTSEL mode.

- [ ] **Step 4: No code commit (this is a hardware verification step)**

Note success in the user-facing report.

---

## Phase G: Wrap-up

### Task 23: Fill timing benchmark

**Files:**
- Create: `mrbgems/picoruby-ili9342/examples/benchmark_fill.rb`
- Modify: `mrbgems/picoruby-ili9342/README.md`

- [ ] **Step 1: Write benchmark**

`mrbgems/picoruby-ili9342/examples/benchmark_fill.rb`:

```ruby
require 'spi'
require 'gpio'
require 'ili9342'

SCK_PIN  = <SCK>
MOSI_PIN = <MOSI>
CS_PIN   = <CS>
DC_PIN   = <DC>
RST_PIN  = <RST>
BL_PIN   = <BL>

spi = SPI.new(unit: :ESP32_SPI2_HOST, frequency: 40_000_000,
              sck_pin: SCK_PIN, copi_pin: MOSI_PIN, cs_pin: CS_PIN, mode: 0)
display = ILI9342.new(
  spi: spi,
  dc_pin:  GPIO.new(DC_PIN,  GPIO::OUT),
  cs_pin:  GPIO.new(CS_PIN,  GPIO::OUT),
  rst_pin: GPIO.new(RST_PIN, GPIO::OUT),
  bl_pin:  GPIO.new(BL_PIN,  GPIO::OUT),
  width: 320, height: 240, rotation: :landscape
)

ITER = 5
total_us = 0
ITER.times do
  start = Machine.uptime_us
  display.fill(ILI9342::Color::BLACK)
  total_us += Machine.uptime_us - start
end

avg_ms = (total_us.to_f / ITER) / 1000.0
puts "fill() x#{ITER} avg: #{avg_ms.round(2)} ms"
```

- [ ] **Step 2: 🔌 HARDWARE — run, capture average ms**

Record the printed value (e.g. `fill() x5 avg: 187.4 ms`).

- [ ] **Step 3: Append to README.md**

In `mrbgems/picoruby-ili9342/README.md`, add section:

```markdown
## Performance baseline (CoreS3, mruby VM, 40 MHz SPI)

| Operation | Avg over 5 runs |
| --- | --- |
| `fill()` full-screen 320×240 | <X.Y> ms |

Measured by `examples/benchmark_fill.rb`. If `fill` becomes a bottleneck for animation, the chunked-write path is the C-port candidate (see future spec).
```

Replace `<X.Y>` with the measured value.

- [ ] **Step 4: Commit**

```bash
git add mrbgems/picoruby-ili9342/examples/benchmark_fill.rb mrbgems/picoruby-ili9342/README.md && git commit -m "feat(examples): fill timing benchmark + README perf section"
```

---

### Task 24: Project root README

**Files:**
- Create: `/Users/bash/dev/src/github.com/m5stack/stackchan-picoruby/README.md`

- [ ] **Step 1: Write root README**

```markdown
# stackchan-picoruby

Personal port of [M5Stack StackChan](https://www.switch-science.com/products/11129) to [PicoRuby](https://github.com/picoruby/picoruby) on [R2P2-ESP32](https://github.com/picoruby/R2P2-ESP32). Architecture is "PC ↔ StackChan via serial": StackChan runs PicoRuby drivers and serves as I/O peripheral, while a host Ruby program (using local Apple Foundation Model) does the AI orchestration.

The official M5Stack firmware lives in the sibling directory `../StackChan` and is treated **read-only** — pin numbers and init sequences are referenced from there but never modified.

## Status (2026-05)

| Subsystem | State | Driver mrbgem |
| --- | --- | --- |
| LCD (ILI9342) | working on CoreS3 | `mrbgems/picoruby-ili9342` |
| Face render (3 expressions) | working in `examples/` of `picoruby-ili9342` | — |
| IMU (BMI270) | not started | `picoruby-bmi270` (planned) |
| Servo (SCServo) | not started | `picoruby-scservo` (planned) |
| Touch (FT6336) | not started | `picoruby-ft6336` (planned) |
| RGB LED (SK6812) | not started | wrapper of upstream `adafruit_sk6812` (planned) |
| USB-Serial host protocol | not started | (planned) |
| BLE-Serial | not started, blocking on ESP32 BLE port | (long-term) |
| Camera / Mic / Speaker | unscoped | far future |

## Repository layout

```
stackchan-picoruby/
├── docs/superpowers/
│   ├── specs/   ← per-subproject design docs
│   └── plans/   ← per-subproject implementation plans
└── mrbgems/
    └── picoruby-ili9342/
        ├── mrblib/, sig/, test/, examples/
        ├── docs/cores3-pinout-and-init.md
        └── README.md
```

Each `mrbgems/picoruby-*` directory is shaped like a standalone PicoRuby gem (mrbgem.rake / Rakefile / mrblib / sig / test / examples), so it can be split into its own repository for upstream PR submission once stable.

## Build + flash (CoreS3)

See `mrbgems/picoruby-ili9342/README.md` for the per-driver usage. The recipe to flash a CoreS3 with this monorepo's gems wired in:

```bash
cd /Users/bash/dev/src/github.com/bash0C7/R2P2-ESP32
export SDKCONFIG_DEFAULTS="sdkconfigs/usb_console;sdkconfigs/spiram"
rake setup_esp32s3
rake build && rake flash
rake monitor
```

`bash0C7/R2P2-ESP32` carries the build hooks for this monorepo on the `feature/cores3-stackchan` branch.

## License

MIT for code originating in this repository. The official `m5stack/StackChan` repository — referenced for pin numbers and init sequences — has its own license; see `docs/upstream-license-note.md`.
```

- [ ] **Step 2: Commit**

```bash
git add README.md && git commit -m "docs: project root README with status matrix and build recipe"
```

---

## Self-Review

After all tasks complete, run this self-check (don't dispatch a subagent — do it yourself):

1. **Spec coverage** — for each receive criterion in `docs/superpowers/specs/2026-05-10-stackchan-display-bringup-design.md` section 2, point to the task that satisfies it:
   - Goal #1 (R2P2 boot via USB-Serial) → Task 4
   - Goal #2 (`require 'ili9342'`) → Task 16
   - Goal #3 (REPL drawing API) → Task 16 step 3
   - Goal #4 (`avatar_demo` 3 expressions × 5s) → Task 21
   - Goal #5 (single face_*.rb scripts) → Tasks 19, 20
   - Goal #6 (autostart via `home/app.rb`) → Task 22
2. **Type consistency** — `set_rotation`, `set_backlight`, `Color::*`, `CMD_*`, `MADCTL_*` names match across mrblib/test/rbs files.
3. **Open `<...>` placeholders** — pin numbers in examples (`<SCK>`, `<MOSI>`, `<CS>`, `<DC>`, `<RST>`, `<BL>`) are intentional substitution points filled in from Task 3 output. Task 17/18/19/20/21/23 each note this. The `<X.Y>` perf number in Task 23 is replaced with measured value at run time. The `<commit>` and `<SPDX-License-Identifier>` in Task 2 are filled at run time.
4. **Hardware checkpoints** — Tasks 4, 16, 17 step 2, 18 step 2, 19 step 4, 20 step 3, 21 step 2, 22, 23 step 2 are 🔌 HARDWARE and will pause subagent flow. Plan adopter must drive these manually.

If anything's missing, fix inline before handing off.
