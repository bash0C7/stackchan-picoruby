# StackChan LED + Protocol Extension Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the StackChan 1-byte protocol with a frame-based one (`<K:V,K:V>`), add LED control with 4 animation modes (solid/blink/breathing/off), and ship a layered driver stack: `picoruby-py32-io-expander` → `picoruby-stackchan-led` → existing `picoruby-stackchan-protocol`.

**Architecture:** Three PicoRuby gems with clean dependency layering. PY32 driver does I2C low-level talk to the M5Stack proprietary IO expander chip (LED RAM at REG 0x30, refresh kick at REG 0x24 bit6). LED gem provides a `picoruby-ws2812`-style API (fill/set_rgb/brightness=/show) plus an Animator that ticks each cycle from the main loop. Protocol gem switches from blocking single-byte read to a non-blocking `STDIN.read_nonblock` polling loop driven by an accumulator-style frame parser (lifted from picoruby-ot). PC client adopts the same frame writer.

**Tech Stack:** PicoRuby (mruby/c on R2P2-ESP32 + ESP32-S3), `picoruby-i2c`, `picoruby-picotest`. Host tests run under CRuby + `test-unit`. PC client uses Ruby 3.x + `uart` + `optparse`.

**Spec:** `docs/superpowers/specs/2026-05-14-stackchan-led-protocol-extension-design.md`

**Reference (do not modify):**
- `/Users/bash/dev/src/github.com/bash0C7/picoruby-mpu6886/` — canonical I2C gem structure & test pattern
- `/Users/bash/dev/src/github.com/m5stack/StackChan/firmware/main/hal/drivers/PY32IOExpander_Class/PY32IOExpander_Class.cpp` — authoritative PY32 register map (line 46-47 for register addresses, line 338-360 for setLedColor / refreshLeds)

---

## Phase 1 — `picoruby-py32-io-expander` gem

### Task 1.1: Scaffold gem directory + build files

**Files:**
- Create: `mrbgems/picoruby-py32-io-expander/mrbgem.rake`
- Create: `mrbgems/picoruby-py32-io-expander/Rakefile`
- Create: `mrbgems/picoruby-py32-io-expander/Gemfile`
- Create: `mrbgems/picoruby-py32-io-expander/.gitignore`
- Create: `mrbgems/picoruby-py32-io-expander/mrblib/py32_io_expander.rb` (stub)
- Create: `mrbgems/picoruby-py32-io-expander/test/test_helper.rb`

- [ ] **Step 1: Create directory structure**

```bash
mkdir -p mrbgems/picoruby-py32-io-expander/mrblib mrbgems/picoruby-py32-io-expander/test
```

- [ ] **Step 2: Write mrbgem.rake**

`mrbgems/picoruby-py32-io-expander/mrbgem.rake`:

```ruby
MRuby::Gem::Specification.new('picoruby-py32-io-expander') do |spec|
  spec.license = 'MIT'
  spec.author  = 'bash0C7'
  spec.summary = 'PY32 IO Expander driver (M5Stack StackChan AI base) - pure Ruby PicoRuby Runtime Gem'

  spec.add_dependency 'picoruby-i2c'
  spec.add_test_dependency 'picoruby-picotest'
end
```

- [ ] **Step 3: Write Rakefile**

`mrbgems/picoruby-py32-io-expander/Rakefile`:

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

- [ ] **Step 4: Write Gemfile**

`mrbgems/picoruby-py32-io-expander/Gemfile`:

```ruby
source "https://rubygems.org"

gem "rake", "~> 13.0"
gem "test-unit", "~> 3.6"
```

- [ ] **Step 5: Write .gitignore**

`mrbgems/picoruby-py32-io-expander/.gitignore`:

```
/vendor/
/Gemfile.lock
```

- [ ] **Step 6: Write mrblib stub**

`mrbgems/picoruby-py32-io-expander/mrblib/py32_io_expander.rb`:

```ruby
class PY32IOExpander
  I2C_ADDRESS       = 0x6F
  REG_LED_CFG       = 0x24
  REG_LED_COUNT     = 0x25
  REG_LED_RAM_START = 0x30

  def initialize(i2c)
    @i2c = i2c
  end
end
```

- [ ] **Step 7: Write test_helper.rb (with FakeI2C + shims)**

`mrbgems/picoruby-py32-io-expander/test/test_helper.rb`:

```ruby
$LOAD_PATH.unshift File.expand_path("../mrblib", __dir__)
$LOAD_PATH.unshift File.expand_path(".", __dir__)

# PicoRuby shim: 'i2c' is a runtime built-in. Mark loaded for host tests.
$LOADED_FEATURES << "i2c" unless $LOADED_FEATURES.include?("i2c")

require "test/unit"

class FakeI2C
  attr_reader :writes, :reads

  def initialize
    @writes = []
    @reads = []
    @read_queue = []
    @raise_on_write = nil
    @raise_on_read = nil
    @write_returns = nil
  end

  attr_accessor :raise_on_write, :raise_on_read, :write_returns

  def queue_read(bytes)
    @read_queue << bytes
  end

  def write(addr, *args, **opts)
    raise @raise_on_write if @raise_on_write
    @writes << { addr: addr, args: args, opts: opts }
    @write_returns || args.flatten.size
  end

  def read(addr, length, reg = nil, **opts)
    raise @raise_on_read if @raise_on_read
    @reads << { addr: addr, length: length, reg: reg, opts: opts }
    @read_queue.shift || ("\x00".b * length)
  end
end

require "py32_io_expander"
```

- [ ] **Step 8: Bundle install + run rake test (expect zero tests)**

```bash
cd mrbgems/picoruby-py32-io-expander && bundle install && bundle exec rake test
```

Expected: `0 tests, 0 assertions, 0 failures` (or similar — just confirming Rakefile loads).

- [ ] **Step 9: Commit scaffold**

Delegate via `commit-commands:commit` skill or general-purpose subagent. Stage explicitly:

```bash
git add mrbgems/picoruby-py32-io-expander/{mrbgem.rake,Rakefile,Gemfile,.gitignore,mrblib,test}
```

Commit message: `feat(picoruby-py32-io-expander): scaffold gem with mpu6886 layout`

---

### Task 1.2: FakeI2C harness self-test

**Files:**
- Create: `mrbgems/picoruby-py32-io-expander/test/py32_io_expander_test.rb` (start)

- [ ] **Step 1: Write FakeI2C harness tests**

Append to `test/py32_io_expander_test.rb`:

```ruby
require "test_helper"

class FakeI2CHarnessTest < Test::Unit::TestCase
  def test_write_records_call
    i2c = FakeI2C.new
    i2c.write(0x6F, 0x24, 0x40)
    assert_equal 1, i2c.writes.size
    assert_equal 0x6F, i2c.writes.first[:addr]
    assert_equal [0x24, 0x40], i2c.writes.first[:args]
  end

  def test_write_returns_args_count_by_default
    i2c = FakeI2C.new
    result = i2c.write(0x6F, 0x24, 0x40, 0x55)
    assert_equal 3, result
  end

  def test_write_returns_override_when_set
    i2c = FakeI2C.new
    i2c.write_returns = 0
    assert_equal 0, i2c.write(0x6F, 0x24)
  end

  def test_read_serves_queued_bytes
    i2c = FakeI2C.new
    i2c.queue_read("\x12".b)
    assert_equal "\x12".b, i2c.read(0x6F, 1, 0x24)
  end

  def test_read_returns_zeros_when_queue_empty
    i2c = FakeI2C.new
    bytes = i2c.read(0x6F, 3, 0x00)
    assert_equal "\x00\x00\x00".b, bytes.b
  end
end
```

- [ ] **Step 2: Run and confirm pass**

```bash
cd mrbgems/picoruby-py32-io-expander && bundle exec rake test
```

Expected: 5 tests pass.

- [ ] **Step 3: Commit**

```bash
git add mrbgems/picoruby-py32-io-expander/test/py32_io_expander_test.rb
```

Commit: `test(picoruby-py32-io-expander): add FakeI2C harness tests`

---

### Task 1.3: PY32IOExpander#initialize + write_reg/read_reg helpers

**Files:**
- Modify: `mrbgems/picoruby-py32-io-expander/mrblib/py32_io_expander.rb`
- Modify: `mrbgems/picoruby-py32-io-expander/test/py32_io_expander_test.rb`

- [ ] **Step 1: Write failing tests for write_reg/read_reg**

Append to `test/py32_io_expander_test.rb`:

```ruby
class PY32WriteRegTest < Test::Unit::TestCase
  def test_write_reg_sends_addr_reg_then_data
    i2c = FakeI2C.new
    py32 = PY32IOExpander.new(i2c)
    py32.send(:write_reg, 0x24, 0x40)
    w = i2c.writes.first
    assert_equal 0x6F, w[:addr]
    assert_equal [0x24, 0x40], w[:args]
  end

  def test_write_reg_passes_timeout
    i2c = FakeI2C.new
    py32 = PY32IOExpander.new(i2c)
    py32.send(:write_reg, 0x24, 0x40)
    assert_equal 1000, i2c.writes.first[:opts][:timeout]
  end

  def test_write_reg_raises_io_error_when_returns_zero
    i2c = FakeI2C.new
    i2c.write_returns = 0
    py32 = PY32IOExpander.new(i2c)
    assert_raises(IOError) { py32.send(:write_reg, 0x24, 0x40) }
  end
end

class PY32ReadRegTest < Test::Unit::TestCase
  def test_read_reg_returns_byte_array
    i2c = FakeI2C.new
    i2c.queue_read("\x42\x55".b)
    py32 = PY32IOExpander.new(i2c)
    bytes = py32.send(:read_reg, 0x10, 2)
    assert_equal [0x42, 0x55], bytes
  end

  def test_read_reg_raises_io_error_when_nil
    i2c = FakeI2C.new
    def i2c.read(*); nil; end
    py32 = PY32IOExpander.new(i2c)
    assert_raises(IOError) { py32.send(:read_reg, 0x10, 1) }
  end

  def test_read_reg_raises_io_error_when_empty
    i2c = FakeI2C.new
    def i2c.read(*); ""; end
    py32 = PY32IOExpander.new(i2c)
    assert_raises(IOError) { py32.send(:read_reg, 0x10, 1) }
  end
end
```

- [ ] **Step 2: Run, confirm 6 fails**

```bash
bundle exec rake test
```

Expected: 6 failures (NoMethodError: undefined method `write_reg`/`read_reg`).

- [ ] **Step 3: Implement write_reg + read_reg**

Replace `mrblib/py32_io_expander.rb` body:

```ruby
class PY32IOExpander
  I2C_ADDRESS       = 0x6F
  REG_LED_CFG       = 0x24
  REG_LED_COUNT     = 0x25
  REG_LED_RAM_START = 0x30

  def initialize(i2c)
    @i2c = i2c
  end

  private

  def write_reg(reg, *data)
    result = @i2c.write(I2C_ADDRESS, reg, *data, timeout: 1000)
    raise IOError, "PY32 write failed (reg: 0x#{reg.to_s(16)})" unless result > 0
    result
  end

  def read_reg(reg, length)
    data = @i2c.read(I2C_ADDRESS, length, reg, timeout: 1000)
    raise IOError, "PY32 read failed (reg: 0x#{reg.to_s(16)})" if data.nil? || data.empty?
    data.bytes
  end
end
```

- [ ] **Step 4: Run, confirm pass**

```bash
bundle exec rake test
```

Expected: 11 tests pass total.

- [ ] **Step 5: Commit**

Commit: `feat(picoruby-py32-io-expander): add write_reg/read_reg I2C helpers`

---

### Task 1.4: set_led_count

**Files:**
- Modify: `mrbgems/picoruby-py32-io-expander/mrblib/py32_io_expander.rb`
- Modify: `mrbgems/picoruby-py32-io-expander/test/py32_io_expander_test.rb`

- [ ] **Step 1: Write failing test**

Append:

```ruby
class PY32SetLedCountTest < Test::Unit::TestCase
  def test_writes_count_to_REG_LED_COUNT
    i2c = FakeI2C.new
    py32 = PY32IOExpander.new(i2c)
    py32.set_led_count(12)
    w = i2c.writes.first
    assert_equal 0x6F, w[:addr]
    assert_equal [0x25, 12], w[:args]
  end
end
```

- [ ] **Step 2: Run, confirm fail**

Expected: NoMethodError: undefined method `set_led_count`.

- [ ] **Step 3: Implement set_led_count**

In `mrblib/py32_io_expander.rb`, before the `private` keyword:

```ruby
  def set_led_count(n)
    write_reg(REG_LED_COUNT, n)
  end
```

- [ ] **Step 4: Run, confirm pass**

Expected: 12 tests pass.

- [ ] **Step 5: Commit**

Commit: `feat(picoruby-py32-io-expander): add set_led_count`

---

### Task 1.5: write_led_ram (RGB888 → RGB565 packing + bulk write)

**Files:**
- Modify: `mrbgems/picoruby-py32-io-expander/mrblib/py32_io_expander.rb`
- Modify: `mrbgems/picoruby-py32-io-expander/test/py32_io_expander_test.rb`

The PY32 stores each pixel as 2 bytes RGB565 big-endian (high byte first), starting at REG 0x30. Verified from `PY32IOExpander_Class.cpp` line 338-342.

- [ ] **Step 1: Write failing tests**

Append:

```ruby
class PY32WriteLedRamTest < Test::Unit::TestCase
  def test_writes_to_REG_LED_RAM_START
    i2c = FakeI2C.new
    py32 = PY32IOExpander.new(i2c)
    py32.write_led_ram([[255, 0, 0]])
    w = i2c.writes.first
    assert_equal 0x6F, w[:addr]
    assert_equal 0x30, w[:args].first
  end

  def test_packs_red_to_rgb565_high_byte_first
    # red 255 -> r5=0x1F=11111, g6=0, b5=0
    # RGB565 = 11111000 00000000 = 0xF800 -> bytes [0xF8, 0x00]
    i2c = FakeI2C.new
    py32 = PY32IOExpander.new(i2c)
    py32.write_led_ram([[255, 0, 0]])
    args = i2c.writes.first[:args]
    assert_equal [0x30, 0xF8, 0x00], args
  end

  def test_packs_green_to_rgb565
    # green 255 -> r5=0, g6=0x3F=111111, b5=0
    # RGB565 = 00000111 11100000 = 0x07E0 -> [0x07, 0xE0]
    i2c = FakeI2C.new
    py32 = PY32IOExpander.new(i2c)
    py32.write_led_ram([[0, 255, 0]])
    args = i2c.writes.first[:args]
    assert_equal [0x30, 0x07, 0xE0], args
  end

  def test_packs_blue_to_rgb565
    # blue 255 -> r5=0, g6=0, b5=0x1F
    # RGB565 = 00000000 00011111 = 0x001F -> [0x00, 0x1F]
    i2c = FakeI2C.new
    py32 = PY32IOExpander.new(i2c)
    py32.write_led_ram([[0, 0, 255]])
    args = i2c.writes.first[:args]
    assert_equal [0x30, 0x00, 0x1F], args
  end

  def test_packs_white_full_intensity
    # white 255,255,255 -> r5=0x1F, g6=0x3F, b5=0x1F
    # RGB565 = 11111111 11111111 = 0xFFFF -> [0xFF, 0xFF]
    i2c = FakeI2C.new
    py32 = PY32IOExpander.new(i2c)
    py32.write_led_ram([[255, 255, 255]])
    args = i2c.writes.first[:args]
    assert_equal [0x30, 0xFF, 0xFF], args
  end

  def test_writes_multiple_pixels_in_one_bulk_call
    i2c = FakeI2C.new
    py32 = PY32IOExpander.new(i2c)
    py32.write_led_ram([[255, 0, 0], [0, 255, 0]])
    assert_equal 1, i2c.writes.size, "must be one bulk I2C transaction"
    args = i2c.writes.first[:args]
    assert_equal [0x30, 0xF8, 0x00, 0x07, 0xE0], args
  end

  def test_handles_12_pixels
    i2c = FakeI2C.new
    py32 = PY32IOExpander.new(i2c)
    pixels = Array.new(12) { [255, 255, 255] }
    py32.write_led_ram(pixels)
    args = i2c.writes.first[:args]
    # 1 reg byte + 12 pixels * 2 bytes = 25 bytes
    assert_equal 25, args.size
    assert_equal 0x30, args.first
  end
end
```

- [ ] **Step 2: Run, confirm 7 fails**

Expected: NoMethodError: undefined method `write_led_ram`.

- [ ] **Step 3: Implement write_led_ram**

In `mrblib/py32_io_expander.rb`, add as public method (before `private`):

```ruby
  def write_led_ram(pixels)
    bytes = []
    pixels.each do |rgb|
      r, g, b = rgb[0], rgb[1], rgb[2]
      r5 = (r >> 3) & 0x1F
      g6 = (g >> 2) & 0x3F
      b5 = (b >> 3) & 0x1F
      packed = (r5 << 11) | (g6 << 5) | b5
      bytes << ((packed >> 8) & 0xFF)
      bytes << (packed & 0xFF)
    end
    write_reg(REG_LED_RAM_START, *bytes)
  end
```

- [ ] **Step 4: Run, confirm pass**

Expected: 19 tests pass.

- [ ] **Step 5: Commit**

Commit: `feat(picoruby-py32-io-expander): add write_led_ram with RGB565 packing`

---

### Task 1.6: refresh_leds

The PY32 latches the LED RAM into output by setting bit 6 of REG_LED_CFG (0x24). Verified from `PY32IOExpander_Class.cpp` line 357-360.

**Files:**
- Modify: `mrbgems/picoruby-py32-io-expander/mrblib/py32_io_expander.rb`
- Modify: `mrbgems/picoruby-py32-io-expander/test/py32_io_expander_test.rb`

- [ ] **Step 1: Write failing test**

Append:

```ruby
class PY32RefreshLedsTest < Test::Unit::TestCase
  def test_writes_bit6_to_REG_LED_CFG
    i2c = FakeI2C.new
    py32 = PY32IOExpander.new(i2c)
    py32.refresh_leds
    w = i2c.writes.first
    assert_equal 0x6F, w[:addr]
    assert_equal [0x24, 0x40], w[:args], "bit 6 = 0x40"
  end
end
```

- [ ] **Step 2: Run, confirm fail**

- [ ] **Step 3: Implement**

In `mrblib/py32_io_expander.rb`, add (before `private`):

```ruby
  def refresh_leds
    write_reg(REG_LED_CFG, 0x40)
  end
```

- [ ] **Step 4: Run, confirm pass**

Expected: 20 tests pass.

- [ ] **Step 5: Commit**

Commit: `feat(picoruby-py32-io-expander): add refresh_leds (REG_LED_CFG bit6)`

---

### Task 1.7: README

**Files:**
- Create: `mrbgems/picoruby-py32-io-expander/README.md`

- [ ] **Step 1: Write README**

`mrbgems/picoruby-py32-io-expander/README.md`:

````markdown
# picoruby-py32-io-expander

PY32 IO Expander driver for the M5Stack StackChan AI Desktop Robot (M5Stack 11129) base unit.

The PY32 chip is an I2C device at address `0x6F` that wraps an internal WS2812-style LED controller (12 pixels at REG `0x30`+) and 16 GPIO pins (P0-P15). Used by the StackChan AI base for the eye-row LED ring and servo power switching.

This gem is a pure-Ruby PicoRuby Runtime Gem. It does NOT generate WS2812 timing on the host — it writes color data over I2C and lets the PY32 chip do the bit-banging. There is no GPIO data line for WS2812 protocol exposed on ESP32-S3 in this hardware.

## Installation

Add to your `build_config/xtensa-esp-picoruby.rb`:

```ruby
conf.gem gemdir: '/path/to/mrbgems/picoruby-py32-io-expander'
```

Depends on `picoruby-i2c`.

## Quick start

```ruby
require 'i2c'
require 'py32_io_expander'

i2c = I2C.new(unit: :ESP32_I2C0, frequency: 400_000, sda_pin: 12, scl_pin: 11)
py32 = PY32IOExpander.new(i2c)

py32.set_led_count(12)
py32.write_led_ram(Array.new(12) { [255, 0, 0] })  # all red
py32.refresh_leds
```

## API

| Method | Description |
|---|---|
| `PY32IOExpander.new(i2c)` | Wraps an I2C instance. Address `0x6F` is fixed. |
| `set_led_count(n)` | Tells the chip how many LEDs to drive. Writes to REG `0x25`. |
| `write_led_ram(pixels)` | `pixels` = `[[r,g,b], ...]`. Packs to RGB565 big-endian, bulk-writes starting at REG `0x30`. |
| `refresh_leds` | Latches the LED RAM into the WS2812 output. Sets bit 6 of REG `0x24`. |

All methods raise `IOError` on I2C failure.

## References

- Authoritative register map: `M5Stack/StackChan/firmware/main/hal/drivers/PY32IOExpander_Class/PY32IOExpander_Class.cpp` line 46-47, line 338-360
- Spec: `docs/superpowers/specs/2026-05-14-stackchan-led-protocol-extension-design.md`
- Layout reference: [picoruby-mpu6886](https://github.com/bash0C7/picoruby-mpu6886)

## License

MIT
````

- [ ] **Step 2: Commit**

Commit: `docs(picoruby-py32-io-expander): add README`

---

## Phase 2 — `picoruby-stackchan-led` gem

### Task 2.1: Scaffold gem

**Files:**
- Create: `mrbgems/picoruby-stackchan-led/mrbgem.rake`
- Create: `mrbgems/picoruby-stackchan-led/Rakefile`
- Create: `mrbgems/picoruby-stackchan-led/Gemfile`
- Create: `mrbgems/picoruby-stackchan-led/.gitignore`
- Create: `mrbgems/picoruby-stackchan-led/mrblib/stackchan_led.rb` (stub)
- Create: `mrbgems/picoruby-stackchan-led/mrblib/stackchan_led/animator.rb` (stub)
- Create: `mrbgems/picoruby-stackchan-led/test/test_helper.rb`

- [ ] **Step 1: Create directory structure**

```bash
mkdir -p mrbgems/picoruby-stackchan-led/mrblib/stackchan_led mrbgems/picoruby-stackchan-led/test
```

- [ ] **Step 2: Write mrbgem.rake**

```ruby
MRuby::Gem::Specification.new('picoruby-stackchan-led') do |spec|
  spec.license = 'MIT'
  spec.author  = 'bash0C7'
  spec.summary = 'StackChan AI 12-pixel LED driver with 4-mode animation - pure Ruby PicoRuby Runtime Gem'

  spec.add_dependency 'picoruby-py32-io-expander'
  spec.add_test_dependency 'picoruby-picotest'
end
```

- [ ] **Step 3: Write Rakefile (same as Task 1.1 step 3)**

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

- [ ] **Step 4: Write Gemfile (same as Task 1.1 step 4)**

```ruby
source "https://rubygems.org"

gem "rake", "~> 13.0"
gem "test-unit", "~> 3.6"
```

- [ ] **Step 5: Write .gitignore**

```
/vendor/
/Gemfile.lock
```

- [ ] **Step 6: Write mrblib stubs**

`mrbgems/picoruby-stackchan-led/mrblib/stackchan_led.rb`:

```ruby
class StackchanLed
  PIXEL_COUNT = 12

  def initialize(py32)
    @py32 = py32
  end
end
```

`mrbgems/picoruby-stackchan-led/mrblib/stackchan_led/animator.rb`:

```ruby
class StackchanLed
  class Animator
    def initialize(led)
      @led = led
    end
  end
end
```

- [ ] **Step 7: Write test_helper.rb**

`mrbgems/picoruby-stackchan-led/test/test_helper.rb`:

```ruby
$LOAD_PATH.unshift File.expand_path("../mrblib", __dir__)
$LOAD_PATH.unshift File.expand_path(".", __dir__)

# Stub PY32IOExpander require so the gem can `require 'py32_io_expander'`
# without the real gem being installed in host CRuby. Tests inject FakePY32.
$LOADED_FEATURES << "py32_io_expander" unless $LOADED_FEATURES.include?("py32_io_expander")
unless defined?(PY32IOExpander)
  class PY32IOExpander
    def initialize(*); end
  end
end

require "test/unit"

class FakePY32
  attr_reader :led_count_calls, :led_ram_calls, :refresh_calls

  def initialize
    @led_count_calls = []
    @led_ram_calls = []
    @refresh_calls = 0
  end

  def set_led_count(n); @led_count_calls << n; end
  def write_led_ram(pixels); @led_ram_calls << pixels.map(&:dup); end
  def refresh_leds; @refresh_calls += 1; end
end

require "stackchan_led"
require "stackchan_led/animator"
```

- [ ] **Step 8: Bundle install + run rake test**

```bash
cd mrbgems/picoruby-stackchan-led && bundle install && bundle exec rake test
```

Expected: `0 tests` (just confirming load).

- [ ] **Step 9: Commit**

```bash
git add mrbgems/picoruby-stackchan-led/{mrbgem.rake,Rakefile,Gemfile,.gitignore,mrblib,test}
```

Commit: `feat(picoruby-stackchan-led): scaffold gem with FakePY32 test harness`

---

### Task 2.2: FakePY32 harness self-test + StackchanLed#initialize

**Files:**
- Create: `mrbgems/picoruby-stackchan-led/test/stackchan_led_test.rb`

- [ ] **Step 1: Write tests**

```ruby
require "test_helper"

class FakePY32HarnessTest < Test::Unit::TestCase
  def test_records_set_led_count
    py32 = FakePY32.new
    py32.set_led_count(12)
    assert_equal [12], py32.led_count_calls
  end

  def test_records_write_led_ram
    py32 = FakePY32.new
    py32.write_led_ram([[1, 2, 3]])
    assert_equal [[[1, 2, 3]]], py32.led_ram_calls
  end

  def test_records_refresh_count
    py32 = FakePY32.new
    py32.refresh_leds
    py32.refresh_leds
    assert_equal 2, py32.refresh_calls
  end
end

class StackchanLedInitializeTest < Test::Unit::TestCase
  def test_sets_led_count_on_init
    py32 = FakePY32.new
    StackchanLed.new(py32)
    assert_equal [12], py32.led_count_calls
  end

  def test_writes_blank_buffer_on_init
    py32 = FakePY32.new
    StackchanLed.new(py32)
    assert_equal 1, py32.led_ram_calls.size
    assert_equal Array.new(12) { [0, 0, 0] }, py32.led_ram_calls.first
  end

  def test_refreshes_after_init_blank
    py32 = FakePY32.new
    StackchanLed.new(py32)
    assert_equal 1, py32.refresh_calls
  end
end
```

- [ ] **Step 2: Run, confirm fails**

Expected: 3 fails on `StackchanLedInitializeTest` (init doesn't call set_led_count or push to PY32).

- [ ] **Step 3: Update StackchanLed#initialize**

Replace `mrbgems/picoruby-stackchan-led/mrblib/stackchan_led.rb`:

```ruby
require 'py32_io_expander'

class StackchanLed
  PIXEL_COUNT = 12

  def initialize(py32)
    @py32 = py32
    @brightness = 100
    @buffer = Array.new(PIXEL_COUNT) { [0, 0, 0] }
    @py32.set_led_count(PIXEL_COUNT)
    show
  end

  def show
    pixels = @buffer.map { |rgb| apply_brightness(rgb[0], rgb[1], rgb[2]) }
    @py32.write_led_ram(pixels)
    @py32.refresh_leds
    self
  end

  private

  def apply_brightness(r, g, b)
    [r * @brightness / 100, g * @brightness / 100, b * @brightness / 100]
  end
end
```

- [ ] **Step 4: Run, confirm pass**

Expected: 6 tests pass.

- [ ] **Step 5: Commit**

Commit: `feat(picoruby-stackchan-led): initialize with blank buffer + show`

---

### Task 2.3: fill / set_rgb / clear

**Files:**
- Modify: `mrbgems/picoruby-stackchan-led/mrblib/stackchan_led.rb`
- Modify: `mrbgems/picoruby-stackchan-led/test/stackchan_led_test.rb`

- [ ] **Step 1: Write tests**

Append:

```ruby
class StackchanLedFillTest < Test::Unit::TestCase
  def test_fill_overwrites_all_pixels
    py32 = FakePY32.new
    led = StackchanLed.new(py32)
    py32.led_ram_calls.clear  # ignore init blank
    py32.refresh_calls = 0 if py32.respond_to?(:refresh_calls=)
    led.fill(255, 0, 0).show
    last = py32.led_ram_calls.last
    assert_equal 12, last.size
    last.each { |rgb| assert_equal [255, 0, 0], rgb }
  end

  def test_fill_returns_self_for_chaining
    led = StackchanLed.new(FakePY32.new)
    assert_same led, led.fill(0, 0, 0)
  end
end

class StackchanLedSetRgbTest < Test::Unit::TestCase
  def test_set_rgb_changes_only_one_pixel
    py32 = FakePY32.new
    led = StackchanLed.new(py32)
    led.set_rgb(3, 100, 200, 50).show
    pixels = py32.led_ram_calls.last
    assert_equal [100, 200, 50], pixels[3]
    assert_equal [0, 0, 0], pixels[0]
    assert_equal [0, 0, 0], pixels[11]
  end
end

class StackchanLedClearTest < Test::Unit::TestCase
  def test_clear_resets_all_to_zero
    py32 = FakePY32.new
    led = StackchanLed.new(py32)
    led.fill(255, 255, 255).show
    led.clear.show
    pixels = py32.led_ram_calls.last
    pixels.each { |rgb| assert_equal [0, 0, 0], rgb }
  end
end
```

- [ ] **Step 2: Run, confirm fails**

Expected: NoMethodError on fill / set_rgb / clear.

- [ ] **Step 3: Implement**

In `mrblib/stackchan_led.rb`, add (before `show`):

```ruby
  def fill(r, g, b)
    @buffer = Array.new(PIXEL_COUNT) { [r, g, b] }
    self
  end

  def set_rgb(i, r, g, b)
    @buffer[i] = [r, g, b]
    self
  end

  def clear
    fill(0, 0, 0)
  end
```

- [ ] **Step 4: Run, confirm pass**

Expected: 10 tests pass.

- [ ] **Step 5: Add `attr_writer :refresh_calls` to FakePY32 if needed**

If the previous step's test uses `py32.refresh_calls = 0`, add `attr_accessor :refresh_calls` (or just remove that line since each new fixture creates a fresh FakePY32).

The simpler approach: re-instantiate `FakePY32.new` per test (already done in setup). Drop the manual reset line.

- [ ] **Step 6: Commit**

Commit: `feat(picoruby-stackchan-led): add fill / set_rgb / clear`

---

### Task 2.4: brightness=

**Files:**
- Modify: `mrbgems/picoruby-stackchan-led/mrblib/stackchan_led.rb`
- Modify: `mrbgems/picoruby-stackchan-led/test/stackchan_led_test.rb`

- [ ] **Step 1: Write tests**

Append:

```ruby
class StackchanLedBrightnessTest < Test::Unit::TestCase
  def test_brightness_default_is_100_no_attenuation
    py32 = FakePY32.new
    led = StackchanLed.new(py32)
    led.fill(100, 200, 50).show
    assert_equal [100, 200, 50], py32.led_ram_calls.last.first
  end

  def test_brightness_50_halves_values
    py32 = FakePY32.new
    led = StackchanLed.new(py32)
    led.brightness = 50
    led.fill(100, 200, 50).show
    assert_equal [50, 100, 25], py32.led_ram_calls.last.first
  end

  def test_brightness_0_blanks
    py32 = FakePY32.new
    led = StackchanLed.new(py32)
    led.brightness = 0
    led.fill(255, 255, 255).show
    assert_equal [0, 0, 0], py32.led_ram_calls.last.first
  end

  def test_brightness_clamps_above_100
    py32 = FakePY32.new
    led = StackchanLed.new(py32)
    led.brightness = 150
    led.fill(100, 0, 0).show
    assert_equal [100, 0, 0], py32.led_ram_calls.last.first
  end

  def test_brightness_clamps_below_0
    py32 = FakePY32.new
    led = StackchanLed.new(py32)
    led.brightness = -50
    led.fill(100, 0, 0).show
    assert_equal [0, 0, 0], py32.led_ram_calls.last.first
  end
end
```

- [ ] **Step 2: Run, confirm fails (brightness= not defined)**

- [ ] **Step 3: Implement**

In `mrblib/stackchan_led.rb`, add (before `show`):

```ruby
  def brightness=(v)
    @brightness = clamp(v, 0, 100)
    self
  end
```

And the helper in `private` section:

```ruby
  def clamp(v, lo, hi)
    v < lo ? lo : (v > hi ? hi : v)
  end
```

- [ ] **Step 4: Run, confirm pass**

Expected: 15 tests pass.

- [ ] **Step 5: Commit**

Commit: `feat(picoruby-stackchan-led): add brightness= with clamp`

---

### Task 2.5: animate API + Animator skeleton + solid mode

**Files:**
- Modify: `mrbgems/picoruby-stackchan-led/mrblib/stackchan_led.rb`
- Modify: `mrbgems/picoruby-stackchan-led/mrblib/stackchan_led/animator.rb`
- Modify: `mrbgems/picoruby-stackchan-led/test/stackchan_led_test.rb`

- [ ] **Step 1: Write tests**

Append:

```ruby
class StackchanLedAnimateSolidTest < Test::Unit::TestCase
  def setup
    @py32 = FakePY32.new
    @led = StackchanLed.new(@py32)
  end

  def test_animate_solid_pushes_color_immediately
    @led.animate(100, 200, 50, :solid)
    assert_equal [100, 200, 50], @py32.led_ram_calls.last.first
  end

  def test_animate_solid_then_tick_does_not_change
    @led.animate(100, 200, 50, :solid)
    calls_before = @py32.led_ram_calls.size
    @led.tick(123)
    @led.tick(500)
    @led.tick(2000)
    assert_equal calls_before, @py32.led_ram_calls.size, "solid is static; tick is no-op"
  end
end

class StackchanLedAnimateOffTest < Test::Unit::TestCase
  def setup
    @py32 = FakePY32.new
    @led = StackchanLed.new(@py32)
  end

  def test_animate_off_clears_immediately
    @led.fill(255, 255, 255).show
    @led.animate(99, 99, 99, :off)
    assert_equal [0, 0, 0], @py32.led_ram_calls.last.first
  end

  def test_animate_off_tick_no_op
    @led.animate(0, 0, 0, :off)
    calls_before = @py32.led_ram_calls.size
    @led.tick(100)
    assert_equal calls_before, @py32.led_ram_calls.size
  end
end
```

- [ ] **Step 2: Run, confirm fails**

Expected: NoMethodError on `animate` and `tick`.

- [ ] **Step 3: Implement Animator with solid + off, plus animate + tick on Strip**

`mrbgems/picoruby-stackchan-led/mrblib/stackchan_led/animator.rb`:

```ruby
class StackchanLed
  class Animator
    def initialize(led)
      @led = led
      @r = 0
      @g = 0
      @b = 0
      @mode = :off
      @phase_start_ms = nil
    end

    def set(r, g, b, mode)
      @r = r
      @g = g
      @b = b
      @mode = mode
      @phase_start_ms = nil
      apply_immediately
    end

    def tick(now_ms)
      return unless dynamic?
      @phase_start_ms ||= now_ms
      # blink and breathing implementations land in later tasks
    end

    private

    def dynamic?
      @mode == :blink || @mode == :breathing
    end

    def apply_immediately
      case @mode
      when :solid
        @led.fill(@r, @g, @b).show
      when :off
        @led.clear.show
      end
    end
  end
end
```

In `mrbgems/picoruby-stackchan-led/mrblib/stackchan_led.rb`, add `require 'stackchan_led/animator'` near the top (after the py32_io_expander require), and inside the class:

```ruby
  def animate(r, g, b, mode)
    animator.set(r, g, b, mode)
    self
  end

  def tick(now_ms)
    animator.tick(now_ms)
  end

  private

  def animator
    @animator ||= Animator.new(self)
  end
```

- [ ] **Step 4: Run, confirm pass**

Expected: 19 tests pass.

- [ ] **Step 5: Commit**

Commit: `feat(picoruby-stackchan-led): add Animator with solid + off modes`

---

### Task 2.6: Animator blink mode

Blink: 500ms ON / 500ms OFF (1Hz). Tick boundary at 0/500/1000/1500ms etc.

**Files:**
- Modify: `mrbgems/picoruby-stackchan-led/mrblib/stackchan_led/animator.rb`
- Modify: `mrbgems/picoruby-stackchan-led/test/stackchan_led_test.rb`

- [ ] **Step 1: Write tests**

Append:

```ruby
class AnimatorBlinkTest < Test::Unit::TestCase
  def setup
    @py32 = FakePY32.new
    @led = StackchanLed.new(@py32)
    @py32.led_ram_calls.clear
  end

  def test_blink_first_tick_is_on
    @led.animate(255, 0, 0, :blink)
    @led.tick(0)
    assert_equal [255, 0, 0], @py32.led_ram_calls.last.first
  end

  def test_blink_at_499ms_still_on
    @led.animate(255, 0, 0, :blink)
    @led.tick(0)
    @led.tick(499)
    assert_equal [255, 0, 0], @py32.led_ram_calls.last.first
  end

  def test_blink_at_500ms_off
    @led.animate(255, 0, 0, :blink)
    @led.tick(0)
    @led.tick(500)
    assert_equal [0, 0, 0], @py32.led_ram_calls.last.first
  end

  def test_blink_at_1000ms_on_again
    @led.animate(255, 0, 0, :blink)
    @led.tick(0)
    @led.tick(1000)
    assert_equal [255, 0, 0], @py32.led_ram_calls.last.first
  end

  def test_blink_phase_anchored_to_first_tick
    @led.animate(255, 0, 0, :blink)
    @led.tick(7000)  # first tick sets phase_start_ms = 7000
    @led.tick(7499)  # elapsed 499 -> still on
    assert_equal [255, 0, 0], @py32.led_ram_calls.last.first
    @led.tick(7500)  # elapsed 500 -> off
    assert_equal [0, 0, 0], @py32.led_ram_calls.last.first
  end
end
```

- [ ] **Step 2: Run, confirm fails**

- [ ] **Step 3: Implement blink in Animator#tick**

Replace the `tick` method in `mrblib/stackchan_led/animator.rb`:

```ruby
    BLINK_HALF_PERIOD_MS = 500

    def tick(now_ms)
      return unless dynamic?
      @phase_start_ms ||= now_ms
      elapsed = now_ms - @phase_start_ms
      case @mode
      when :blink
        on = (elapsed / BLINK_HALF_PERIOD_MS) % 2 == 0
        if on
          @led.fill(@r, @g, @b).show
        else
          @led.fill(0, 0, 0).show
        end
      end
    end
```

(Place `BLINK_HALF_PERIOD_MS` constant near the top of the Animator class.)

- [ ] **Step 4: Run, confirm pass**

Expected: 24 tests pass.

- [ ] **Step 5: Commit**

Commit: `feat(picoruby-stackchan-led): add blink animation mode`

---

### Task 2.7: Animator breathing mode

Breathing: 12-step LUT, 250ms per step = 3 second cycle. LUT = `[0, 5, 20, 45, 70, 90, 100, 90, 70, 45, 20, 5]`.

**Files:**
- Modify: `mrbgems/picoruby-stackchan-led/mrblib/stackchan_led/animator.rb`
- Modify: `mrbgems/picoruby-stackchan-led/test/stackchan_led_test.rb`

- [ ] **Step 1: Write tests**

Append:

```ruby
class AnimatorBreathingTest < Test::Unit::TestCase
  def setup
    @py32 = FakePY32.new
    @led = StackchanLed.new(@py32)
    @py32.led_ram_calls.clear
  end

  def test_breathing_first_tick_step_0_is_zero
    @led.animate(100, 0, 0, :breathing)
    @led.tick(0)
    assert_equal [0, 0, 0], @py32.led_ram_calls.last.first
  end

  def test_breathing_at_250ms_step_1
    # LUT[1] = 5%, 100*5/100 = 5
    @led.animate(100, 0, 0, :breathing)
    @led.tick(0)
    @led.tick(250)
    assert_equal [5, 0, 0], @py32.led_ram_calls.last.first
  end

  def test_breathing_at_1500ms_step_6_peak
    # LUT[6] = 100%, full intensity
    @led.animate(200, 100, 50, :breathing)
    @led.tick(0)
    @led.tick(1500)
    assert_equal [200, 100, 50], @py32.led_ram_calls.last.first
  end

  def test_breathing_wraps_at_3000ms
    # 3000ms / 250 = 12, % 12 = 0, LUT[0] = 0
    @led.animate(100, 0, 0, :breathing)
    @led.tick(0)
    @led.tick(3000)
    assert_equal [0, 0, 0], @py32.led_ram_calls.last.first
  end

  def test_breathing_phase_anchored_to_first_tick
    @led.animate(100, 0, 0, :breathing)
    @led.tick(5000)  # phase_start_ms = 5000
    @led.tick(5250)  # elapsed 250 -> step 1 -> 5
    assert_equal [5, 0, 0], @py32.led_ram_calls.last.first
  end
end
```

- [ ] **Step 2: Run, confirm fails**

- [ ] **Step 3: Implement breathing in Animator**

In `mrblib/stackchan_led/animator.rb`, add the LUT constant and a `:breathing` case to the `tick` method's `case`:

```ruby
    BREATHING_LUT = [0, 5, 20, 45, 70, 90, 100, 90, 70, 45, 20, 5].freeze
    BREATHING_STEP_MS = 250
```

In the `case @mode` block, add:

```ruby
      when :breathing
        ratio = BREATHING_LUT[(elapsed / BREATHING_STEP_MS) % BREATHING_LUT.size]
        @led.fill(@r * ratio / 100, @g * ratio / 100, @b * ratio / 100).show
```

- [ ] **Step 4: Run, confirm pass**

Expected: 29 tests pass.

- [ ] **Step 5: Commit**

Commit: `feat(picoruby-stackchan-led): add breathing animation mode (12-step LUT)`

---

### Task 2.8: README

**Files:**
- Create: `mrbgems/picoruby-stackchan-led/README.md`

- [ ] **Step 1: Write README**

````markdown
# picoruby-stackchan-led

12-pixel LED driver for the M5Stack StackChan AI Desktop Robot, with built-in 4-mode animation engine. Sits on top of `picoruby-py32-io-expander`.

API style is loosely modeled after [picoruby-ws2812](https://github.com/ksbmyk/picoruby-ws2812) — `fill` / `set_rgb` / `brightness=` / `show` / `clear`. The chip-level WS2812 timing is generated inside the PY32 microcontroller, not on ESP32-S3.

## Installation

Add to your `build_config/xtensa-esp-picoruby.rb`:

```ruby
conf.gem gemdir: '/path/to/mrbgems/picoruby-py32-io-expander'
conf.gem gemdir: '/path/to/mrbgems/picoruby-stackchan-led'
```

## Quick start

```ruby
require 'i2c'
require 'py32_io_expander'
require 'stackchan_led'

i2c = I2C.new(unit: :ESP32_I2C0, frequency: 400_000, sda_pin: 12, scl_pin: 11)
py32 = PY32IOExpander.new(i2c)
led = StackchanLed.new(py32)

led.fill(255, 0, 0).show       # all red
led.brightness = 50
led.fill(0, 255, 0).show       # all green at 50%

# Animation
led.animate(0, 255, 0, :breathing)
loop do
  led.tick(Machine.uptime_us / 1000)
  sleep_ms 50
end
```

## Animation modes

| Mode | Behavior |
|---|---|
| `:solid` | static color, immediate apply |
| `:blink` | 1Hz on/off (500ms each phase) |
| `:breathing` | 3-second cycle, 12-step intensity LUT |
| `:off` | clear, immediate apply |

## API

| Method | Description |
|---|---|
| `StackchanLed.new(py32)` | Wraps a `PY32IOExpander`. Sets LED count to 12, blanks the strip. |
| `fill(r, g, b)` | Sets all pixels. Returns self. |
| `set_rgb(i, r, g, b)` | Sets one pixel by index. Returns self. |
| `brightness=(v)` | 0-100, clamped. Applies to all subsequent `show`. |
| `clear` | Same as `fill(0, 0, 0)`. |
| `show` | Push current buffer to PY32 (with brightness applied). |
| `animate(r, g, b, mode)` | Set color + animation mode. Solid/off apply immediately; blink/breathing render on next `tick`. |
| `tick(now_ms)` | Advance the animator. Pass `Machine.uptime_us / 1000` from the main task. |

`now_ms` MUST come from the main task (calling `Machine.uptime_us` from a background `Task` causes silent task death on mruby/c).

## References

- Spec: `docs/superpowers/specs/2026-05-14-stackchan-led-protocol-extension-design.md`
- Layout reference: [picoruby-mpu6886](https://github.com/bash0C7/picoruby-mpu6886)
- API inspiration: [picoruby-ws2812](https://github.com/ksbmyk/picoruby-ws2812)

## License

MIT
````

- [ ] **Step 2: Commit**

Commit: `docs(picoruby-stackchan-led): add README`

---

## Phase 3 — `picoruby-stackchan-protocol` refactor (frame parser + Dispatcher)

### Task 3.1: Add FrameParser with TDD

**Files:**
- Create: `mrbgems/picoruby-stackchan-protocol/mrblib/stackchan_protocol/frame_parser.rb`
- Create: `mrbgems/picoruby-stackchan-protocol/test/frame_parser_test.rb`

- [ ] **Step 1: Write tests**

`mrbgems/picoruby-stackchan-protocol/test/frame_parser_test.rb`:

```ruby
require "test_helper"
require "stackchan_protocol/frame_parser"

class FrameParserBasicTest < Test::Unit::TestCase
  def test_decodes_single_frame
    p = StackchanProtocol::FrameParser.new
    frames = p.feed("<F:1>")
    assert_equal [{ "F" => "1" }], frames
  end

  def test_decodes_multi_pair_frame
    p = StackchanProtocol::FrameParser.new
    frames = p.feed("<L:1,R:255,G:0,B:0,M:p>")
    assert_equal [{ "L" => "1", "R" => "255", "G" => "0", "B" => "0", "M" => "p" }], frames
  end

  def test_strips_trailing_newline
    p = StackchanProtocol::FrameParser.new
    frames = p.feed("<F:1>\n")
    assert_equal [{ "F" => "1" }], frames
  end

  def test_returns_empty_for_no_frame
    p = StackchanProtocol::FrameParser.new
    assert_equal [], p.feed("garbage")
  end
end

class FrameParserPartialTest < Test::Unit::TestCase
  def test_holds_partial_frame_until_close_arrives
    p = StackchanProtocol::FrameParser.new
    assert_equal [], p.feed("<F:")
    assert_equal [{ "F" => "1" }], p.feed("1>")
  end

  def test_handles_multiple_chunks_for_one_frame
    p = StackchanProtocol::FrameParser.new
    p.feed("<L:1,")
    p.feed("R:0,")
    frames = p.feed("G:255,B:0,M:s>")
    assert_equal [{ "L" => "1", "R" => "0", "G" => "255", "B" => "0", "M" => "s" }], frames
  end
end

class FrameParserMultiTest < Test::Unit::TestCase
  def test_decodes_multiple_frames_in_one_chunk
    p = StackchanProtocol::FrameParser.new
    frames = p.feed("<F:1><F:2>")
    assert_equal [{ "F" => "1" }, { "F" => "2" }], frames
  end

  def test_garbage_between_frames_skipped
    p = StackchanProtocol::FrameParser.new
    frames = p.feed("zzzz<F:1>asdf<F:2>qwerty")
    assert_equal [{ "F" => "1" }, { "F" => "2" }], frames
  end
end

class FrameParserErrorTest < Test::Unit::TestCase
  def test_empty_frame_increments_error_count
    p = StackchanProtocol::FrameParser.new
    p.feed("<>")
    assert_equal 1, p.parse_error_count
  end

  def test_no_colon_in_pair_skipped
    p = StackchanProtocol::FrameParser.new
    frames = p.feed("<XYZ>")
    # XYZ has no colon -> skipped pair -> empty hash -> nil decoded -> error
    assert_equal 1, p.parse_error_count
    assert_equal [], frames
  end

  def test_bad_pair_among_good_pairs_keeps_good
    p = StackchanProtocol::FrameParser.new
    frames = p.feed("<F:1,bogus,L:1>")
    assert_equal [{ "F" => "1", "L" => "1" }], frames
  end
end

class FrameParserBufferOverflowTest < Test::Unit::TestCase
  def test_buffer_truncated_at_4096
    p = StackchanProtocol::FrameParser.new
    big = "X" * 5000
    p.feed(big)
    # The buffer should be trimmed; subsequent valid frame should still parse.
    frames = p.feed("<F:1>")
    assert_equal [{ "F" => "1" }], frames
  end
end
```

- [ ] **Step 2: Write FrameParser**

`mrbgems/picoruby-stackchan-protocol/mrblib/stackchan_protocol/frame_parser.rb`:

```ruby
module StackchanProtocol
  class FrameParser
    MAX_BUFFER = 4096

    attr_reader :parse_error_count

    def initialize
      @buffer = String.new
      @parse_error_count = 0
    end

    def feed(chunk)
      @buffer << chunk
      if @buffer.bytesize > MAX_BUFFER
        @buffer = @buffer[(@buffer.bytesize - MAX_BUFFER), MAX_BUFFER]
      end
      frames = []
      while (s = @buffer.index('<'))
        e = @buffer.index('>', s)
        break unless e
        raw = @buffer[s, e - s + 1]
        @buffer = @buffer[(e + 1), @buffer.bytesize - (e + 1)] || ""
        decoded = decode(raw)
        if decoded
          frames << decoded
        else
          @parse_error_count += 1
        end
      end
      frames
    end

    private

    def decode(raw)
      return nil if raw.bytesize < 3
      body = raw[1, raw.bytesize - 2]
      return nil if body.nil? || body.empty?
      h = {}
      body.split(',').each do |pair|
        kv = pair.split(':', 2)
        next unless kv.size == 2
        h[kv[0]] = kv[1]
      end
      h.empty? ? nil : h
    end
  end
end
```

- [ ] **Step 3: Run tests**

```bash
cd mrbgems/picoruby-stackchan-protocol && bundle exec rake test
```

Expected: all FrameParser tests pass (~13 new tests). Existing 1-byte tests still pass too — they will be removed in Task 3.4.

- [ ] **Step 4: Commit**

Commit: `feat(picoruby-stackchan-protocol): add FrameParser (picoruby-ot accumulator pattern)`

---

### Task 3.2: Add FakeLed to test fixtures

**Files:**
- Create: `mrbgems/picoruby-stackchan-protocol/test/fake_led.rb`
- Modify: `mrbgems/picoruby-stackchan-protocol/test/test_helper.rb`

- [ ] **Step 1: Write FakeLed**

`mrbgems/picoruby-stackchan-protocol/test/fake_led.rb`:

```ruby
class FakeLed
  attr_reader :animate_calls, :tick_calls

  def initialize
    @animate_calls = []
    @tick_calls = []
  end

  def animate(r, g, b, mode)
    @animate_calls << [r, g, b, mode]
    self
  end

  def tick(now_ms)
    @tick_calls << now_ms
  end

  def last_animate_args
    @animate_calls.last
  end
end
```

- [ ] **Step 2: Update test_helper to load FakeLed**

In `mrbgems/picoruby-stackchan-protocol/test/test_helper.rb`, add at the bottom (before `require "stackchan_protocol"`):

```ruby
require "fake_led"
```

- [ ] **Step 3: Run tests, confirm green**

Expected: all existing tests still pass; FakeLed loadable.

- [ ] **Step 4: Commit**

Commit: `test(picoruby-stackchan-protocol): add FakeLed fixture`

---

### Task 3.3: Refactor Dispatcher to handle Hash frames

**Files:**
- Modify: `mrbgems/picoruby-stackchan-protocol/mrblib/stackchan_protocol.rb` (delete old Dispatcher, add new)
- Create: `mrbgems/picoruby-stackchan-protocol/mrblib/stackchan_protocol/dispatcher.rb`
- Create: `mrbgems/picoruby-stackchan-protocol/test/dispatcher_test.rb`

- [ ] **Step 1: Write tests**

`mrbgems/picoruby-stackchan-protocol/test/dispatcher_test.rb`:

```ruby
require "test_helper"
require "stackchan_protocol/dispatcher"

class DispatcherFaceTest < Test::Unit::TestCase
  def setup
    @display = FakeDisplay.new
    @led     = FakeLed.new
    @stdout  = FakeStdout.new
    @disp    = StackchanProtocol::Dispatcher.new(
      display: @display, led: @led, stdout: @stdout
    )
  end

  def test_F_0_draws_neutral
    @disp.handle({ "F" => "0" })
    methods = @display.calls.map(&:first)
    assert_equal [:fill, :draw_ellipse, :draw_ellipse, :draw_line, :draw_line], methods
  end

  def test_F_1_draws_smile
    @disp.handle({ "F" => "1" })
    line = @display.calls.select { |c| c.first == :draw_line }.first.last
    assert_equal 132, line[1]
  end

  def test_F_2_draws_joy
    @disp.handle({ "F" => "2" })
    line = @display.calls.select { |c| c.first == :draw_line }.first.last
    assert_equal 122, line[1]
  end

  def test_F_3_draws_surprised
    @disp.handle({ "F" => "3" })
    methods = @display.calls.map(&:first)
    assert_equal [:fill, :draw_ellipse, :draw_ellipse, :draw_rect], methods
  end

  def test_F_unknown_writes_error
    @disp.handle({ "F" => "9" })
    assert_equal ["?"], @stdout.writes
  end

  def test_F_valid_writes_ack
    @disp.handle({ "F" => "0" })
    assert_equal ["."], @stdout.writes
  end
end

class DispatcherLedTest < Test::Unit::TestCase
  def setup
    @display = FakeDisplay.new
    @led     = FakeLed.new
    @stdout  = FakeStdout.new
    @disp    = StackchanProtocol::Dispatcher.new(
      display: @display, led: @led, stdout: @stdout
    )
  end

  def test_L_solid_sends_animate
    @disp.handle({ "L" => "1", "R" => "100", "G" => "200", "B" => "50", "M" => "s" })
    assert_equal [100, 200, 50, :solid], @led.last_animate_args
  end

  def test_L_blink
    @disp.handle({ "L" => "1", "R" => "255", "G" => "0", "B" => "0", "M" => "b" })
    assert_equal [255, 0, 0, :blink], @led.last_animate_args
  end

  def test_L_breathing
    @disp.handle({ "L" => "1", "R" => "0", "G" => "255", "B" => "0", "M" => "p" })
    assert_equal [0, 255, 0, :breathing], @led.last_animate_args
  end

  def test_L_off_no_rgb
    @disp.handle({ "L" => "1", "M" => "o" })
    assert_equal [0, 0, 0, :off], @led.last_animate_args
  end

  def test_L_unknown_mode_writes_error
    @disp.handle({ "L" => "1", "R" => "0", "G" => "0", "B" => "0", "M" => "x" })
    assert_equal ["?"], @stdout.writes
    assert_nil @led.last_animate_args
  end

  def test_L_valid_writes_ack
    @disp.handle({ "L" => "1", "M" => "o" })
    assert_equal ["."], @stdout.writes
  end
end

class DispatcherCombinedTest < Test::Unit::TestCase
  def setup
    @display = FakeDisplay.new
    @led     = FakeLed.new
    @stdout  = FakeStdout.new
    @disp    = StackchanProtocol::Dispatcher.new(
      display: @display, led: @led, stdout: @stdout
    )
  end

  def test_F_and_L_both_dispatched
    @disp.handle({ "F" => "1", "L" => "1", "R" => "0", "G" => "255", "B" => "0", "M" => "s" })
    methods = @display.calls.map(&:first)
    assert_includes methods, :draw_ellipse
    assert_equal [0, 255, 0, :solid], @led.last_animate_args
  end

  def test_combined_success_writes_single_ack
    @disp.handle({ "F" => "1", "L" => "1", "R" => "0", "G" => "255", "B" => "0", "M" => "s" })
    assert_equal ["."], @stdout.writes
  end

  def test_combined_partial_failure_writes_error
    @disp.handle({ "F" => "9", "L" => "1", "M" => "o" })
    assert_equal ["?"], @stdout.writes
  end

  def test_unknown_keys_only_writes_error
    @disp.handle({ "Z" => "1" })
    assert_equal ["?"], @stdout.writes
  end

  def test_display_exception_writes_error
    @display.raise_on_fill = StandardError.new("boom")
    @disp.handle({ "F" => "0" })
    assert_equal ["?"], @stdout.writes
  end
end
```

- [ ] **Step 2: Write Dispatcher class**

`mrbgems/picoruby-stackchan-protocol/mrblib/stackchan_protocol/dispatcher.rb`:

```ruby
module StackchanProtocol
  class Dispatcher
    ERROR_BYTE = "?"
    ACK_BYTE   = "."

    FACE_TABLE = {
      "0" => Face::Neutral,
      "1" => Face::Smile,
      "2" => Face::Joy,
      "3" => Face::Surprised,
    }.freeze

    MODE_TABLE = {
      "s" => :solid,
      "b" => :blink,
      "p" => :breathing,
      "o" => :off,
    }.freeze

    def initialize(display:, led:, stdout: $stdout)
      @display = display
      @led     = led
      @stdout  = stdout
    end

    def handle(frame)
      attempts = []
      attempts << handle_face(frame) if frame.key?("F")
      attempts << handle_led(frame)  if frame.key?("L")
      success = !attempts.empty? && attempts.all? { |ok| ok }
      @stdout.write(success ? ACK_BYTE : ERROR_BYTE)
    rescue => e
      log_error(e)
      @stdout.write(ERROR_BYTE)
    end

    private

    def handle_face(frame)
      face_class = FACE_TABLE[frame["F"]]
      return false unless face_class
      face_class.new.draw(@display)
      true
    end

    def handle_led(frame)
      mode = MODE_TABLE[frame["M"]]
      return false unless mode
      r = (frame["R"] || "0").to_i
      g = (frame["G"] || "0").to_i
      b = (frame["B"] || "0").to_i
      @led.animate(r, g, b, mode)
      true
    end

    def log_error(e)
      # No-op for now; on-device logging would go here.
    end
  end
end
```

- [ ] **Step 3: Update top-level mrblib to require new files + drop old Dispatcher**

In `mrbgems/picoruby-stackchan-protocol/mrblib/stackchan_protocol.rb`, **delete** the entire `class Dispatcher ... end` block (lines 81-115 of the existing file). At the very bottom of the file, add:

```ruby
require 'stackchan_protocol/frame_parser'
require 'stackchan_protocol/dispatcher'
```

(Keep the `module StackchanProtocol; module Face; ...; end; end` Face/Base/Neutral/Smile/Joy/Surprised classes unchanged.)

- [ ] **Step 4: Run tests, confirm new dispatcher tests pass**

```bash
bundle exec rake test
```

Expected: new dispatcher tests pass (~17). Old `DispatcherHandleByteTest` and `DispatcherRunTest` will FAIL — those will be deleted in Task 3.4.

- [ ] **Step 5: Commit**

Commit: `feat(picoruby-stackchan-protocol): replace 1-byte Dispatcher with frame Dispatcher`

---

### Task 3.4: Delete obsolete 1-byte tests

**Files:**
- Modify: `mrbgems/picoruby-stackchan-protocol/test/stackchan_protocol_test.rb`

- [ ] **Step 1: Delete obsolete test classes**

In `test/stackchan_protocol_test.rb`, delete:
- `DispatcherHandleByteTest` (lines 186-254)
- `DispatcherRunTest` (lines 256-292)

Keep all Face / FakeDisplay / FakeStdout / FakeStdin harness tests (lines 1-184).

(`FakeStdin` itself stays — it's still useful for future tests of any blocking-read scenarios — but the unused tests for it can stay too; they're cheap.)

- [ ] **Step 2: Run tests, confirm green**

```bash
bundle exec rake test
```

Expected: all remaining tests pass. No DispatcherHandleByteTest / DispatcherRunTest in the output.

- [ ] **Step 3: Commit**

Commit: `test(picoruby-stackchan-protocol): drop 1-byte Dispatcher tests (replaced by Frame Dispatcher)`

---

### Task 3.5: Update mrbgem.rake to add stackchan-led dependency

**Files:**
- Modify: `mrbgems/picoruby-stackchan-protocol/mrbgem.rake`

- [ ] **Step 1: Add dependency**

Replace `mrbgems/picoruby-stackchan-protocol/mrbgem.rake` body:

```ruby
MRuby::Gem::Specification.new('picoruby-stackchan-protocol') do |spec|
  spec.license = 'MIT'
  spec.author  = 'bash0C7'
  spec.summary = 'StackChan ⇔ PC USB-serial frame protocol dispatcher with face + LED'

  spec.add_dependency 'picoruby-ili9342'
  spec.add_dependency 'picoruby-stackchan-led'
  spec.add_test_dependency 'picoruby-picotest'
end
```

- [ ] **Step 2: Commit**

Commit: `chore(picoruby-stackchan-protocol): depend on picoruby-stackchan-led`

---

### Task 3.6: Rewrite examples/app.rb to tick loop (drop cycling demo)

**Files:**
- Modify: `mrbgems/picoruby-stackchan-protocol/examples/app.rb`

- [ ] **Step 1: Replace app.rb**

Replace the entire file with:

```ruby
# examples/app.rb — autostart entry for StackChan AI base.
#
# Cold-boot init must run BEFORE LCD or LED traffic:
#   1. AXP2101 PMIC must enable DLDO1 (LCD power + backlight rail).
#   2. AW9523 IO Expander P1.1 must be pulsed to release LCD reset.
#   3. PY32 IO Expander handles LED data internally; no separate enable needed.
# A cold-boot (USB unplug) leaves DLDO1 OFF, so the LCD init block is mandatory.

require 'spi'
require 'gpio'
require 'i2c'
require 'machine'
require 'ili9342'
require 'py32_io_expander'
require 'stackchan_led'
require 'stackchan-protocol'

I2C_SDA_PIN  = 12
I2C_SCL_PIN  = 11
AXP2101_ADDR = 0x34
AW9523_ADDR  = 0x58

i2c = I2C.new(unit: :ESP32_I2C0, frequency: 400_000,
              sda_pin: I2C_SDA_PIN, scl_pin: I2C_SCL_PIN)

# AXP2101: enable DLDO1 (bit 7 of reg 0x90) and set its voltage (reg 0x99).
i2c.write(AXP2101_ADDR, 0x90, 0xBF)
i2c.write(AXP2101_ADDR, 0x99, 24)

# AW9523: P1 push-pull output, then pulse LCD RST (P1.1).
i2c.write(AW9523_ADDR, 0x04, 0b00011000)
i2c.write(AW9523_ADDR, 0x05, 0b00001100)
i2c.write(AW9523_ADDR, 0x11, 0b00010000)
i2c.write(AW9523_ADDR, 0x03, 0b10000001)
Machine.delay_ms(20)
i2c.write(AW9523_ADDR, 0x03, 0b10000011)
Machine.delay_ms(10)

# ILI9342 SPI bus + display init.
SCK_PIN       = 36
MOSI_PIN      = 37
CS_PIN        = 3
DC_PIN        = 35
DUMMY_RST_PIN = 1
DUMMY_BL_PIN  = 2

spi = SPI.new(unit: :ESP32_SPI3_HOST, frequency: 40_000_000,
              sck_pin: SCK_PIN, copi_pin: MOSI_PIN, mode: 2)
display = ILI9342.new(
  spi: spi,
  dc_pin:  GPIO.new(DC_PIN,  GPIO::OUT),
  cs_pin:  GPIO.new(CS_PIN,  GPIO::OUT),
  rst_pin: GPIO.new(DUMMY_RST_PIN, GPIO::OUT),
  bl_pin:  GPIO.new(DUMMY_BL_PIN,  GPIO::OUT),
  width: 320, height: 240, rotation: :landscape
)

# PY32 IO Expander + LED driver (LEDs default to all-off via StackchanLed#init).
py32 = PY32IOExpander.new(i2c)
led  = StackchanLed.new(py32)

# Initial face: neutral.
StackchanProtocol::Face::Neutral.new.draw(display)

# Frame protocol: parser + dispatcher.
parser     = StackchanProtocol::FrameParser.new
dispatcher = StackchanProtocol::Dispatcher.new(display: display, led: led)

TICK_MS = 50
loop do
  tick_start_ms = Machine.uptime_us / 1000
  chunk = STDIN.read_nonblock(256)
  if chunk
    parser.feed(chunk).each { |f| dispatcher.handle(f) }
  end
  led.tick(tick_start_ms)
  elapsed = (Machine.uptime_us / 1000) - tick_start_ms
  remaining = TICK_MS - elapsed
  sleep_ms(remaining) if remaining > 0
end
```

- [ ] **Step 2: Commit**

Commit: `feat(picoruby-stackchan-protocol): rewrite app.rb as tick loop with LED + frame parser`

---

## Phase 4 — PC client refactor

### Task 4.1: Add FrameWriter

**Files:**
- Create: `pc/stackchan-protocol/lib/stackchan_protocol/frame_writer.rb`
- Create: `pc/stackchan-protocol/test/frame_writer_test.rb`

- [ ] **Step 1: Write tests**

`pc/stackchan-protocol/test/frame_writer_test.rb`:

```ruby
require "test_helper"
require "stackchan_protocol/frame_writer"

class FrameWriterTest < Test::Unit::TestCase
  def test_simple_face
    assert_equal "<F:1>\n", StackchanProtocol::FrameWriter.encode(F: "1")
  end

  def test_led_with_rgb_and_mode
    encoded = StackchanProtocol::FrameWriter.encode(L: "1", R: 255, G: 0, B: 0, M: "s")
    assert_equal "<L:1,R:255,G:0,B:0,M:s>\n", encoded
  end

  def test_combined_face_and_led
    encoded = StackchanProtocol::FrameWriter.encode(F: "1", L: "1", R: 0, G: 255, B: 0, M: "s")
    assert_equal "<F:1,L:1,R:0,G:255,B:0,M:s>\n", encoded
  end

  def test_off_only
    encoded = StackchanProtocol::FrameWriter.encode(L: "1", M: "o")
    assert_equal "<L:1,M:o>\n", encoded
  end

  def test_integer_values_stringified
    encoded = StackchanProtocol::FrameWriter.encode(R: 42)
    assert_equal "<R:42>\n", encoded
  end

  def test_symbol_keys_become_strings
    encoded = StackchanProtocol::FrameWriter.encode(F: "1")
    assert_match(/F:1/, encoded)
  end
end
```

- [ ] **Step 2: Implement**

`pc/stackchan-protocol/lib/stackchan_protocol/frame_writer.rb`:

```ruby
module StackchanProtocol
  module FrameWriter
    module_function

    def encode(**pairs)
      body = pairs.map { |k, v| "#{k}:#{v}" }.join(",")
      "<#{body}>\n"
    end
  end
end
```

- [ ] **Step 3: Run, confirm pass**

```bash
cd pc/stackchan-protocol && bundle exec rake test
```

- [ ] **Step 4: Commit**

Commit: `feat(pc/stackchan-protocol): add FrameWriter`

---

### Task 4.2: Add LedColorTable

**Files:**
- Create: `pc/stackchan-protocol/lib/stackchan_protocol/led_color_table.rb`
- Create: `pc/stackchan-protocol/test/led_color_table_test.rb`

- [ ] **Step 1: Write tests**

```ruby
require "test_helper"
require "stackchan_protocol/led_color_table"

class LedColorTableTest < Test::Unit::TestCase
  def test_red
    assert_equal [255, 0, 0], StackchanProtocol::LED_COLORS.fetch("red")
  end

  def test_green
    assert_equal [0, 255, 0], StackchanProtocol::LED_COLORS.fetch("green")
  end

  def test_blue
    assert_equal [0, 0, 255], StackchanProtocol::LED_COLORS.fetch("blue")
  end

  def test_white
    assert_equal [255, 255, 255], StackchanProtocol::LED_COLORS.fetch("white")
  end

  def test_off_is_zeros
    assert_equal [0, 0, 0], StackchanProtocol::LED_COLORS.fetch("off")
  end

  def test_yellow
    assert_equal [255, 255, 0], StackchanProtocol::LED_COLORS.fetch("yellow")
  end

  def test_cyan
    assert_equal [0, 255, 255], StackchanProtocol::LED_COLORS.fetch("cyan")
  end

  def test_magenta
    assert_equal [255, 0, 255], StackchanProtocol::LED_COLORS.fetch("magenta")
  end

  def test_table_frozen
    assert_predicate StackchanProtocol::LED_COLORS, :frozen?
  end

  def test_unknown_raises_key_error
    assert_raises(KeyError) { StackchanProtocol::LED_COLORS.fetch("puce") }
  end
end

class LedModeTableTest < Test::Unit::TestCase
  def test_solid
    assert_equal "s", StackchanProtocol::LED_MODES.fetch("solid")
  end

  def test_blink
    assert_equal "b", StackchanProtocol::LED_MODES.fetch("blink")
  end

  def test_breathing
    assert_equal "p", StackchanProtocol::LED_MODES.fetch("breathing")
  end

  def test_off
    assert_equal "o", StackchanProtocol::LED_MODES.fetch("off")
  end

  def test_table_frozen
    assert_predicate StackchanProtocol::LED_MODES, :frozen?
  end
end
```

- [ ] **Step 2: Implement**

`pc/stackchan-protocol/lib/stackchan_protocol/led_color_table.rb`:

```ruby
module StackchanProtocol
  LED_COLORS = {
    "red"     => [255, 0,   0],
    "green"   => [0,   255, 0],
    "blue"    => [0,   0,   255],
    "yellow"  => [255, 255, 0],
    "cyan"    => [0,   255, 255],
    "magenta" => [255, 0,   255],
    "white"   => [255, 255, 255],
    "off"     => [0,   0,   0],
  }.freeze

  LED_MODES = {
    "solid"     => "s",
    "blink"     => "b",
    "breathing" => "p",
    "off"       => "o",
  }.freeze
end
```

- [ ] **Step 3: Run, confirm pass**

- [ ] **Step 4: Commit**

Commit: `feat(pc/stackchan-protocol): add LedColorTable + LedModeTable`

---

### Task 4.3: Refactor face_table to frame indices, update Client

**Files:**
- Modify: `pc/stackchan-protocol/lib/stackchan_protocol/face_table.rb`
- Modify: `pc/stackchan-protocol/lib/stackchan_protocol/client.rb`
- Modify: `pc/stackchan-protocol/test/client_test.rb` (update expected writes from `"1"` to `"<F:1>\n"` etc.)

- [ ] **Step 1: Update face_table.rb (constants stay the same — they're already frame indices)**

The existing `FACE_BYTES = { neutral: "0", ... }` works as-is for frame indices. Rename to `FACE_INDICES` for clarity:

`pc/stackchan-protocol/lib/stackchan_protocol/face_table.rb`:

```ruby
module StackchanProtocol
  FACE_INDICES = {
    neutral:   "0",
    smile:     "1",
    joy:       "2",
    surprised: "3",
  }.freeze
end
```

- [ ] **Step 2: Update existing face_table tests**

In `pc/stackchan-protocol/test/client_test.rb`, replace `FACE_BYTES` references with `FACE_INDICES` (lines 5-23 of that file have `FaceTableTest`).

- [ ] **Step 3: Refactor Client to use FrameWriter**

Replace `pc/stackchan-protocol/lib/stackchan_protocol/client.rb`:

```ruby
require "uart"
require_relative "face_table"
require_relative "led_color_table"
require_relative "frame_writer"

module StackchanProtocol
  class DeviceError < StandardError; end

  class Client
    attr_reader :port, :baud, :ack_timeout

    def initialize(port:, baud: 115_200, ack_timeout: 0.5, uart_class: UART)
      @port = port
      @baud = baud
      @ack_timeout = ack_timeout
      @uart_class = uart_class
    end

    def open(&block)
      @uart_class.open(@port, @baud, &block)
    end

    def raw_send(serial, frame_string)
      serial.write(frame_string)
      read_ack(serial, "raw send")
    end

    def set_face(serial, name)
      index = FACE_INDICES.fetch(name)
      send_frame(serial, "face=#{name}", F: index)
    end

    def set_led(serial, color_name, mode_name = "solid")
      r, g, b = LED_COLORS.fetch(color_name)
      mode    = LED_MODES.fetch(mode_name)
      if mode == "o"
        send_frame(serial, "led=off", L: "1", M: mode)
      else
        send_frame(serial, "led=#{color_name} #{mode_name}",
                   L: "1", R: r, G: g, B: b, M: mode)
      end
    end

    def set_combo(serial, face_name:, color_name:, mode_name: "solid")
      face = FACE_INDICES.fetch(face_name)
      r, g, b = LED_COLORS.fetch(color_name)
      mode    = LED_MODES.fetch(mode_name)
      send_frame(serial, "combo=#{face_name}+#{color_name}/#{mode_name}",
                 F: face, L: "1", R: r, G: g, B: b, M: mode)
    end

    def drain(serial, timeout: 1.0)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      buf = +""
      loop do
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        break if remaining <= 0
        ready = serial.wait_readable(0)
        break if ready.nil?
        chunk = serial.read(64) || break
        buf << chunk
      end
      buf
    end

    private

    def send_frame(serial, label, **pairs)
      frame = FrameWriter.encode(**pairs)
      serial.write(frame)
      read_ack(serial, label)
    end

    def read_ack(serial, label)
      ready = serial.wait_readable(@ack_timeout)
      return nil if ready.nil?
      ack = serial.read(1)
      raise DeviceError, "device reported '?' for #{label}" if ack == "?"
      nil
    end
  end
end
```

- [ ] **Step 4: Update client_test.rb expectations**

In `pc/stackchan-protocol/test/client_test.rb`:

Replace `FACE_BYTES` with `FACE_INDICES` everywhere. Update test assertions from raw byte writes to frame strings:

- `assert_equal ["1"], @fake_uart.writes` → `assert_equal ["<F:1>\n"], @fake_uart.writes`
- `assert_equal ["0"], @fake_uart.writes` → `assert_equal ["<F:0>\n"], @fake_uart.writes`
- etc.

Update `ClientRawSendTest`:

```ruby
def test_raw_send_writes_string_as_is
  @client.open do |serial|
    @client.raw_send(serial, "<X:bogus>\n")
  end
  assert_equal ["<X:bogus>\n"], @fake_uart.writes
end
```

- [ ] **Step 5: Run, confirm green**

```bash
cd pc/stackchan-protocol && bundle exec rake test
```

- [ ] **Step 6: Commit**

Commit: `refactor(pc/stackchan-protocol): use FrameWriter; drop 1-byte sends`

---

### Task 4.4: Add Client#set_led + Client#set_combo tests

**Files:**
- Modify: `pc/stackchan-protocol/test/client_test.rb`

- [ ] **Step 1: Append tests**

Append to `client_test.rb`:

```ruby
class ClientSetLedTest < Test::Unit::TestCase
  def setup
    @fake_uart = FakeUart.new
    @fake_uart_class = Class.new do
      def self.open(_port, _baud, &block); block.call(@_fake); end
      class << self; attr_accessor :_fake; end
    end
    @fake_uart_class._fake = @fake_uart
    @client = StackchanProtocol::Client.new(
      port: "/dev/cu.fake", ack_timeout: 0.1, uart_class: @fake_uart_class
    )
  end

  def test_red_solid_writes_frame
    @client.open { |s| @client.set_led(s, "red", "solid") }
    assert_equal ["<L:1,R:255,G:0,B:0,M:s>\n"], @fake_uart.writes
  end

  def test_green_breathing
    @client.open { |s| @client.set_led(s, "green", "breathing") }
    assert_equal ["<L:1,R:0,G:255,B:0,M:p>\n"], @fake_uart.writes
  end

  def test_off_omits_rgb
    @client.open { |s| @client.set_led(s, "off", "off") }
    assert_equal ["<L:1,M:o>\n"], @fake_uart.writes
  end

  def test_default_mode_is_solid
    @client.open { |s| @client.set_led(s, "blue") }
    assert_equal ["<L:1,R:0,G:0,B:255,M:s>\n"], @fake_uart.writes
  end

  def test_unknown_color_raises_key_error
    assert_raises(KeyError) do
      @client.open { |s| @client.set_led(s, "puce") }
    end
  end

  def test_unknown_mode_raises_key_error
    assert_raises(KeyError) do
      @client.open { |s| @client.set_led(s, "red", "rave") }
    end
  end
end

class ClientSetComboTest < Test::Unit::TestCase
  def setup
    @fake_uart = FakeUart.new
    @fake_uart_class = Class.new do
      def self.open(_port, _baud, &block); block.call(@_fake); end
      class << self; attr_accessor :_fake; end
    end
    @fake_uart_class._fake = @fake_uart
    @client = StackchanProtocol::Client.new(
      port: "/dev/cu.fake", ack_timeout: 0.1, uart_class: @fake_uart_class
    )
  end

  def test_combo_smile_green_solid
    @client.open do |s|
      @client.set_combo(s, face_name: :smile, color_name: "green", mode_name: "solid")
    end
    assert_equal ["<F:1,L:1,R:0,G:255,B:0,M:s>\n"], @fake_uart.writes
  end
end
```

- [ ] **Step 2: Run, confirm pass**

- [ ] **Step 3: Commit**

Commit: `test(pc/stackchan-protocol): add set_led + set_combo client tests`

---

### Task 4.5: Update CLI with `led`, `combo`, updated `raw`

**Files:**
- Modify: `pc/stackchan-protocol/lib/stackchan_protocol/cli.rb`
- Modify: `pc/stackchan-protocol/test/cli_test.rb`

- [ ] **Step 1: Replace CLI**

`pc/stackchan-protocol/lib/stackchan_protocol/cli.rb`:

```ruby
require "optparse"
require_relative "client"

module StackchanProtocol
  module CLI
    module_function

    def run(argv, env: ENV.to_h, uart_class: UART, stderr: $stderr, stdout: $stdout)
      port = nil
      face_for_combo = nil
      led_for_combo = nil
      OptionParser.new do |opts|
        opts.on("--port PORT", "Serial port path") { |p| port = p }
        opts.on("--face NAME",  "Face name (combo only)")             { |f| face_for_combo = f }
        opts.on("--led SPEC",   "LED spec '<color> <mode>' (combo)")  { |l| led_for_combo = l }
      end.parse!(argv)

      port ||= env["STACKCHAN_PORT"]
      unless port
        stderr.puts "error: --port required (or set STACKCHAN_PORT)"
        return 2
      end

      command = argv.shift
      unless command
        stderr.puts "error: command required (face / led / combo / raw)"
        return 2
      end

      client = Client.new(port: port, uart_class: uart_class)
      begin
        client.open do |serial|
          case command
          when "face"
            name = argv.shift
            unless name
              stderr.puts "error: face requires <name>"
              return 2
            end
            client.set_face(serial, name.to_sym)
          when "led"
            color = argv.shift
            mode  = argv.shift || "solid"
            unless color
              stderr.puts "error: led requires <color> [<mode>]"
              return 2
            end
            client.set_led(serial, color, mode)
          when "combo"
            unless face_for_combo && led_for_combo
              stderr.puts "error: combo requires --face NAME --led '<color> <mode>'"
              return 2
            end
            color, mode = led_for_combo.split(/\s+/, 2)
            mode ||= "solid"
            client.set_combo(serial,
                             face_name: face_for_combo.to_sym,
                             color_name: color,
                             mode_name: mode)
          when "raw"
            frame = argv.shift
            unless frame
              stderr.puts "error: raw requires a frame string"
              return 2
            end
            client.raw_send(serial, frame.end_with?("\n") ? frame : frame + "\n")
          else
            stderr.puts "error: unknown command '#{command}'"
            return 2
          end
        end
        0
      rescue DeviceError => e
        stderr.puts "device error: #{e.message}"
        1
      rescue KeyError => e
        stderr.puts "unknown name: #{e.message}"
        2
      end
    end
  end
end
```

- [ ] **Step 2: Update existing cli_test.rb**

Update `CliArgParsingTest`:

- `["--port", "/dev/cu.test", "neutral"]` → `["--port", "/dev/cu.test", "face", "neutral"]`
- `["smile"]` → `["face", "smile"]`
- Expected writes: `["0"]` → `["<F:0>\n"]`, `["1"]` → `["<F:1>\n"]`

Update `CliRawCommandTest`:

- `["raw", "9"]` → `["raw", "<X:bogus>"]`
- Expected writes: `["9"]` → `["<X:bogus>\n"]`

Update `CliUnknownFaceTest`:

- `["rage"]` → `["face", "rage"]`

Add new test class `CliLedCommandTest`:

```ruby
class CliLedCommandTest < Test::Unit::TestCase
  def setup
    @fake_uart = FakeUart.new
    @fake_uart_class = Class.new do
      def self.open(_port, _baud, &block); block.call(@_fake); end
      class << self; attr_accessor :_fake; end
    end
    @fake_uart_class._fake = @fake_uart
    @stderr = StringIO.new
  end

  def test_led_red_default_solid
    StackchanProtocol::CLI.run(
      ["--port", "/dev/cu.test", "led", "red"],
      env: {}, uart_class: @fake_uart_class, stderr: @stderr
    )
    assert_equal ["<L:1,R:255,G:0,B:0,M:s>\n"], @fake_uart.writes
  end

  def test_led_green_breathing
    StackchanProtocol::CLI.run(
      ["--port", "/dev/cu.test", "led", "green", "breathing"],
      env: {}, uart_class: @fake_uart_class, stderr: @stderr
    )
    assert_equal ["<L:1,R:0,G:255,B:0,M:p>\n"], @fake_uart.writes
  end

  def test_led_off
    StackchanProtocol::CLI.run(
      ["--port", "/dev/cu.test", "led", "off", "off"],
      env: {}, uart_class: @fake_uart_class, stderr: @stderr
    )
    assert_equal ["<L:1,M:o>\n"], @fake_uart.writes
  end

  def test_led_missing_color_exits_two
    status = StackchanProtocol::CLI.run(
      ["--port", "/dev/cu.test", "led"],
      env: {}, uart_class: @fake_uart_class, stderr: @stderr
    )
    assert_equal 2, status
  end
end

class CliComboCommandTest < Test::Unit::TestCase
  def setup
    @fake_uart = FakeUart.new
    @fake_uart_class = Class.new do
      def self.open(_port, _baud, &block); block.call(@_fake); end
      class << self; attr_accessor :_fake; end
    end
    @fake_uart_class._fake = @fake_uart
    @stderr = StringIO.new
  end

  def test_combo_smile_green_solid
    StackchanProtocol::CLI.run(
      ["--port", "/dev/cu.test", "--face", "smile", "--led", "green solid", "combo"],
      env: {}, uart_class: @fake_uart_class, stderr: @stderr
    )
    assert_equal ["<F:1,L:1,R:0,G:255,B:0,M:s>\n"], @fake_uart.writes
  end

  def test_combo_missing_face_exits_two
    status = StackchanProtocol::CLI.run(
      ["--port", "/dev/cu.test", "--led", "green solid", "combo"],
      env: {}, uart_class: @fake_uart_class, stderr: @stderr
    )
    assert_equal 2, status
  end
end
```

- [ ] **Step 3: Run, confirm green**

```bash
cd pc/stackchan-protocol && bundle exec rake test
```

- [ ] **Step 4: Commit**

Commit: `feat(pc/stackchan-protocol): add led/combo/raw frame commands to CLI`

---

## Phase 5 — Build integration on R2P2-ESP32

### Task 5.1: Register new gems in R2P2-ESP32 build_config

**Files:**
- Modify: `/Users/bash/dev/src/github.com/bash0C7/R2P2-ESP32/components/picoruby-esp32/build_config/xtensa-esp-picoruby.rb`

- [ ] **Step 1: Add 2 conf.gem lines**

In that build_config file, find the existing block (around line 63-65):

```ruby
  # device drivers (out-of-tree, from stackchan-picoruby monorepo)
  conf.gem gemdir: '/Users/bash/dev/src/github.com/m5stack/stackchan-picoruby/mrbgems/picoruby-ili9342'
  conf.gem gemdir: '/Users/bash/dev/src/github.com/m5stack/stackchan-picoruby/mrbgems/picoruby-stackchan-protocol'
```

Replace with:

```ruby
  # device drivers (out-of-tree, from stackchan-picoruby monorepo)
  conf.gem gemdir: '/Users/bash/dev/src/github.com/m5stack/stackchan-picoruby/mrbgems/picoruby-ili9342'
  conf.gem gemdir: '/Users/bash/dev/src/github.com/m5stack/stackchan-picoruby/mrbgems/picoruby-py32-io-expander'
  conf.gem gemdir: '/Users/bash/dev/src/github.com/m5stack/stackchan-picoruby/mrbgems/picoruby-stackchan-led'
  conf.gem gemdir: '/Users/bash/dev/src/github.com/m5stack/stackchan-picoruby/mrbgems/picoruby-stackchan-protocol'
```

(Order matters: `picoruby-stackchan-led` depends on `picoruby-py32-io-expander`, and `picoruby-stackchan-protocol` depends on `picoruby-stackchan-led`. List dependencies first.)

- [ ] **Step 2: Commit (in R2P2-ESP32 repo)**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/R2P2-ESP32
```

Delegate via subagent. Stage:

```bash
git add components/picoruby-esp32/build_config/xtensa-esp-picoruby.rb
```

Commit: `chore: wire picoruby-py32-io-expander + picoruby-stackchan-led from monorepo`

---

### Task 5.2: Rebuild gems and flash device

**Working directory:** `/Users/bash/dev/src/github.com/m5stack/stackchan-picoruby`

- [ ] **Step 1: Rebuild gems (forces gem_init.c regeneration)**

```bash
rake r2p2:rebuild_gems
```

Expected: `tmp/longrun/r2p2_rebuild_gems.log` ends with `DONE: exit=0`.

- [ ] **Step 2: Build + flash**

```bash
rake r2p2:build_flash
```

Expected: `tmp/longrun/r2p2_build_flash.log` ends with `DONE: exit=0` and shows `flash complete`.

- [ ] **Step 3: Watch boot via background log capture**

```bash
cat /dev/cu.usbmodem* > tmp/longrun/serial.log &
SERIAL_PID=$!
sleep 1
rake r2p2:reset
sleep 8
kill $SERIAL_PID
```

Then `Read` `tmp/longrun/serial.log` — confirm R2P2 banner and no Lua/Ruby crash.

- [ ] **Step 4: Verify autostart loads `/home/app.rb`**

Upload latest app.rb to /home if not already there:

```bash
cd pc/stackchan-protocol
bundle exec ruby ../../tmp/picomodem_upload.rb $(pwd)/../../mrbgems/picoruby-stackchan-protocol/examples/app.rb /home/app.rb
```

(See `picomodem-upload-timing` memory: first try may show `FILE_ACK expected got nil`; retry after 6s succeeds.)

```bash
cd ..
rake r2p2:reset
sleep 10
```

**Pass criterion:** Visually inspect device — neutral face on screen, all 12 LEDs OFF.

If LEDs are stuck ON or showing garbage: PY32 init issue. Re-check Task 1.5 RGB565 packing math against `PY32IOExpander_Class.cpp:338-342`.

---

## Phase 6 — Hardware verification

The following are manual hardware steps to be performed once the app is flashed and autostarting (Task 5.2 step 4 passed).

### Task 6.1: Solid LED color sweep

- [ ] **Step 1: Run color sweep**

```bash
cd pc/stackchan-protocol
for color in red green blue yellow cyan magenta white off; do
  bundle exec stackchan-control --port /dev/cu.usbmodem* led $color
  sleep 1
done
```

**Pass criterion:** Each color appears uniformly across all 12 LEDs in the named color, off blanks them. Each invocation exits 0 (ACK received).

### Task 6.2: Animation modes

- [ ] **Step 1: Blink test**

```bash
bundle exec stackchan-control --port /dev/cu.usbmodem* led red blink
sleep 5
```

**Pass criterion:** Red LEDs blink ~1Hz (visible on/off cycle every second).

- [ ] **Step 2: Breathing test**

```bash
bundle exec stackchan-control --port /dev/cu.usbmodem* led green breathing
sleep 10
```

**Pass criterion:** Green LEDs smoothly breathe at ~3 second cycle, peaking at full intensity then dimming to off.

- [ ] **Step 3: Off**

```bash
bundle exec stackchan-control --port /dev/cu.usbmodem* led off off
```

**Pass criterion:** All LEDs go dark immediately, animation stops.

### Task 6.3: Combo frame (face + LED simultaneous)

- [ ] **Step 1: Smile + green solid**

```bash
bundle exec stackchan-control --port /dev/cu.usbmodem* --face smile --led "green solid" combo
```

**Pass criterion:** Face changes to smile AND LEDs go green solid in one command, single ACK.

- [ ] **Step 2: Surprised + red breathing**

```bash
bundle exec stackchan-control --port /dev/cu.usbmodem* --face surprised --led "red breathing" combo
```

**Pass criterion:** Face surprised, LEDs red breathing.

### Task 6.4: Garbage tolerance

- [ ] **Step 1: Send garbage + valid frame**

```bash
bundle exec stackchan-control --port /dev/cu.usbmodem* raw "junk<F:0>more<L:1,M:o>"
```

**Pass criterion:** Face changes to neutral, LEDs off, ACK `.` received.

### Task 6.5: Error frame

- [ ] **Step 1: Send unknown key**

```bash
bundle exec stackchan-control --port /dev/cu.usbmodem* raw "<Z:bogus>"
```

**Pass criterion:** CLI exits with status 1, stderr says "device error". Display unchanged.

---

### Task 6.6: Update STACKCHAN_PROTOCOL_VERIFICATION.md

**Files:**
- Modify: `docs/STACKCHAN_PROTOCOL_VERIFICATION.md`

- [ ] **Step 1: Add new section after the existing protocol verification**

Append to the file:

```markdown
## Phase N — Frame protocol + LED verification (post-extension spec)

After the `2026-05-14-stackchan-led-protocol-extension` plan completes, the
1-byte protocol is gone and the following replaces it.

### Solid color sweep

```bash
for color in red green blue yellow cyan magenta white off; do
  bundle exec stackchan-control --port /dev/cu.usbmodem* led $color
  sleep 1
done
```

**Pass criterion:** Each color uniform on all 12 LEDs; off blanks; each call exits 0.

### Animation modes

```bash
bundle exec stackchan-control --port /dev/cu.usbmodem* led red blink
# wait 5s -> visible 1Hz blink
bundle exec stackchan-control --port /dev/cu.usbmodem* led green breathing
# wait 10s -> 3-second smooth in/out
bundle exec stackchan-control --port /dev/cu.usbmodem* led off off
# blanks instantly
```

### Combo frame

```bash
bundle exec stackchan-control --port /dev/cu.usbmodem* \
  --face smile --led "green solid" combo
```

**Pass criterion:** Face smile + LEDs green solid + single ACK.

### Garbage tolerance

```bash
bundle exec stackchan-control --port /dev/cu.usbmodem* raw "junk<F:0>more<L:1,M:o>"
```

**Pass criterion:** Face neutral, LEDs off, exits 0.

### Error frame

```bash
bundle exec stackchan-control --port /dev/cu.usbmodem* raw "<Z:bogus>"
```

**Pass criterion:** Exits 1, stderr "device error".

### Cold-boot LED check

1. USB unplug for 10s.
2. USB replug.
3. Wait 5s for autostart.
4. Confirm: neutral face on screen, all 12 LEDs OFF (no flash on boot).
```

- [ ] **Step 2: Commit**

Commit: `docs(verification): add frame protocol + LED verification steps`

---

### Task 6.7: Update root README status table

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Locate the status table**

Open `README.md`, find the section that lists current gems / status (was added by previous spec, see commit `ae0c598`).

- [ ] **Step 2: Add 2 new rows**

Add rows for:

```markdown
| `mrbgems/picoruby-py32-io-expander` | PY32 IO Expander I2C driver (LED/GPIO low-level) | ✅ done |
| `mrbgems/picoruby-stackchan-led`    | 12-pixel LED with 4-mode animation                | ✅ done |
```

Update the existing `picoruby-stackchan-protocol` row's description from "1-byte protocol" to "frame protocol".

- [ ] **Step 3: Commit**

Commit: `docs(README): add stackchan-led + py32-io-expander status rows`

---

## Self-Review Notes

Verified before plan was finalized:

1. **Spec coverage** — every section of `2026-05-14-stackchan-led-protocol-extension-design.md` maps to at least one task:
   - §5.1 (PY32 driver) → Phase 1
   - §5.2 (LED gem) → Phase 2
   - §5.3 (protocol gem refactor) → Phase 3
   - §5.4 (PC client) → Phase 4
   - §5.5 (build config) → Task 5.1
   - §6 (wire format) → covered by FrameParser tests + FrameWriter tests
   - §7 (error handling) → covered by Dispatcher error tests + CLI error tests
   - §8 (testing strategy) → embedded in TDD steps; §8.3 hardware verification → Phase 6
   - §9 (no backward compat) → Task 3.4 deletes 1-byte tests; Task 3.6 replaces app.rb

2. **Type/name consistency** — `StackchanLed`, `PY32IOExpander`, `Animator` are spelled consistently. `FACE_INDICES` (renamed from `FACE_BYTES`) and `LED_COLORS` / `LED_MODES` are referenced from Client + tests using exact same names.

3. **No placeholders** — every code block is complete; no TODO / TBD / "fill in".

4. **PicoRuby compatibility** — `STDIN.read_nonblock(256)` (verified available); `Machine.uptime_us / 1000` only called from main task; no `defined?` / `Hash#fetch` (in mrblib code; PC code uses `fetch` which is fine on CRuby); buffer slicing uses explicit `[start, length]` form (not endless ranges).

5. **YAGNI** — no Servo, BLE, WiFi, brightness in protocol, per-pixel addressing. All deferred to later sub-projects per spec §3.2.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-05-14-stackchan-led-protocol-extension.md`. Two execution options:

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints.

Which approach?
