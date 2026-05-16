# BLE Phase 3 — `stackchan-ble-client` SDK + device `application.rb` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** BLE 経由で表情と LED (左右分離・4 色指定形式) をスタックちゃんに送って動かせる SDK + 端末 dispatcher + E2E smoke task を一通り組む。`rake r2p2:ble_control_smoke COLOR=red MODE=blink FACE=joy SIDE=both` が exit 0 で帰り、視認で正しく動いていれば Phase 3 完了。

**Architecture:** Mac 側に新規 `pc/stackchan-ble-client/` gem (高レベル API + `#send` block DSL + frame encoder + corebluetooth_mac transport + CLI exe) を作る。Device 側は新規 `examples/application.rb` で 5s escape hatch + cold-boot init + BLE NUS service + Dispatcher + AckSink + 無限 advertise を一直線に構築。既存 `pc/stackchan-protocol/` gem は完全廃止、`picomodem-upload` は `lib/deploy/picomodem.rb` に module 化して Rakefile から直接呼ぶ。LED driver と Dispatcher は左右分離対応 (`fill_range` / `animate_side` / `S` key) で拡張。

**Tech Stack:** Ruby 3.x (Mac 側 `pc/stackchan-ble-client/`), `corebluetooth_mac` (path: ../rb-corebluetooth-mac), test-unit (host unit tests), PicoRuby (device 側 mrbgems), BTstack (vendored in R2P2-ESP32), Nordic UART Service (BLE), picorbc (host compile)。

**Branch:** `feature/ble-phase3-control` (既に作成済み、spec doc commit 済み)。

**Spec:** `docs/superpowers/specs/2026-05-17-ble-phase3-control-cli-design.md`

---

## File Structure

### Created

```
pc/stackchan-ble-client/
├── stackchan_ble_client.gemspec
├── Gemfile
├── Rakefile
├── README.md
├── lib/stackchan_ble_client.rb                          # autoload entry
├── lib/stackchan_ble_client/
│   ├── version.rb
│   ├── face_table.rb         # FACE_INDICES (symbol → digit-string)
│   ├── led_color_table.rb    # LED_COLORS (symbol → [r,g,b])
│   ├── frame_codec.rb        # encode_face / encode_led / parse_ack
│   ├── hsb_to_rgb.rb         # HSB packed (0xHHSSBB) → [r,g,b]
│   ├── send_builder.rb       # DSL block receiver + (key, side) last-wins aggregation
│   └── client.rb             # connect / send / disconnect (corebluetooth_mac wrap)
├── exe/
│   └── stackchan-ble-control # CLI entry: face / led / led-rgb / led-hsb / combo / raw
└── test/
    ├── test_helper.rb
    ├── frame_codec_test.rb
    ├── hsb_to_rgb_test.rb
    ├── send_builder_test.rb
    ├── face_table_test.rb
    ├── led_color_table_test.rb
    └── client_test.rb        # fake transport で接続〜送信〜ACK 全体

lib/deploy/picomodem.rb       # picomodem-upload を Ruby module 化

mrbgems/picoruby-stackchan-protocol/examples/application.rb
```

### Modified

```
mrbgems/picoruby-stackchan-led/mrblib/stackchan_led.rb
mrbgems/picoruby-stackchan-led/mrblib/stackchan_led/animator.rb
mrbgems/picoruby-stackchan-led/test/stackchan_led_test.rb
mrbgems/picoruby-stackchan-protocol/mrblib/stackchan_protocol/dispatcher.rb
mrbgems/picoruby-stackchan-protocol/test/dispatcher_test.rb
mrbgems/picoruby-stackchan-protocol/test/fake_led.rb
Rakefile                      # r2p2:upload* refactor + delete legacy tasks + add r2p2:ble_control_smoke
```

### Deleted

```
pc/stackchan-protocol/                                     # gem 全体
mrbgems/picoruby-stackchan-protocol/examples/ble_smoke.rb
```

---

## Task 1: Bootstrap `pc/stackchan-ble-client/` gem skeleton

**Files:**
- Create: `pc/stackchan-ble-client/stackchan_ble_client.gemspec`
- Create: `pc/stackchan-ble-client/Gemfile`
- Create: `pc/stackchan-ble-client/Rakefile`
- Create: `pc/stackchan-ble-client/lib/stackchan_ble_client.rb`
- Create: `pc/stackchan-ble-client/lib/stackchan_ble_client/version.rb`
- Create: `pc/stackchan-ble-client/test/test_helper.rb`
- Create: `pc/stackchan-ble-client/.gitignore`

- [ ] **Step 1: Create gem directory + skeleton files**

```bash
mkdir -p pc/stackchan-ble-client/lib/stackchan_ble_client pc/stackchan-ble-client/test pc/stackchan-ble-client/exe
```

`pc/stackchan-ble-client/stackchan_ble_client.gemspec`:

```ruby
require_relative "lib/stackchan_ble_client/version"

Gem::Specification.new do |spec|
  spec.name          = "stackchan_ble_client"
  spec.version       = StackchanBleClient::VERSION
  spec.authors       = ["bash0C7"]
  spec.summary       = "BLE control SDK for the M5Stack StackChan PicoRuby firmware"
  spec.description   = <<~DESC
    High-level BLE client for the StackChan PicoRuby firmware. Connects via Nordic UART
    Service (NUS) and exposes a block DSL (#send do |stackchan| ... end) for face / LED
    frames with side, mode, and 4 color forms (named / RGB hex / HSB hex / mode keyword).
  DESC
  spec.required_ruby_version = ">= 3.1.0"
  spec.files = Dir["lib/**/*.rb", "exe/*", "README.md"]
  spec.executables = ["stackchan-ble-control"]
  spec.require_paths = ["lib"]
end
```

`pc/stackchan-ble-client/Gemfile`:

```ruby
source "https://rubygems.org"

gemspec

gem "corebluetooth_mac", path: "../../../../bash0C7/rb-corebluetooth-mac"
gem "swift_gem",         path: "../../../../bash0C7/rb-corebluetooth-mac/vendor/swift_gem" if File.exist?(File.expand_path("../../../bash0C7/rb-corebluetooth-mac/vendor/swift_gem", __dir__))

group :test do
  gem "test-unit"
  gem "rake"
end
```

Note: the `swift_gem` path-prefix is heuristic. If `bundle install` complains in Step 4, look at `pc/stackchan-protocol/Gemfile` (still on disk) to see how it pinned `corebluetooth_mac` + `swift_gem` and copy that exactly.

`pc/stackchan-ble-client/Rakefile`:

```ruby
require "rake/testtask"

Rake::TestTask.new do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList["test/**/*_test.rb"]
  t.warning = false
end

task default: :test
```

`pc/stackchan-ble-client/lib/stackchan_ble_client/version.rb`:

```ruby
module StackchanBleClient
  VERSION = "0.1.0"
end
```

`pc/stackchan-ble-client/lib/stackchan_ble_client.rb`:

```ruby
require_relative "stackchan_ble_client/version"
require_relative "stackchan_ble_client/face_table"
require_relative "stackchan_ble_client/led_color_table"
require_relative "stackchan_ble_client/hsb_to_rgb"
require_relative "stackchan_ble_client/frame_codec"
require_relative "stackchan_ble_client/send_builder"
require_relative "stackchan_ble_client/client"

module StackchanBleClient
  class Error < StandardError; end
  class TimeoutError < Error; end
  class DeviceError < Error; end
  class ConnectionError < Error; end
end
```

`pc/stackchan-ble-client/test/test_helper.rb`:

```ruby
require "bundler/setup"
require "test-unit"
require "stackchan_ble_client"
```

`pc/stackchan-ble-client/.gitignore`:

```
/.bundle/
/Gemfile.lock
/tmp/
```

- [ ] **Step 2: Stub the missing requires so the loader doesn't blow up before Tasks 2-7 fill them in**

The autoloader chain in `lib/stackchan_ble_client.rb` requires files that don't exist yet. Create empty namespace stubs so `bundle exec rake test` finishes without `LoadError` until those tasks land:

```bash
for f in face_table led_color_table hsb_to_rgb frame_codec send_builder client; do
  echo "module StackchanBleClient; end" > pc/stackchan-ble-client/lib/stackchan_ble_client/${f}.rb
done
```

These stubs are overwritten in Tasks 2-7.

- [ ] **Step 3: Stage and verify gem installs**

Run:

```bash
cd pc/stackchan-ble-client
bundle install
```

Expected: `Bundle complete!`. If `corebluetooth_mac` path is wrong, fix `Gemfile` per the note in Step 1.

- [ ] **Step 4: Verify rake test runs (with zero tests)**

Run:

```bash
cd pc/stackchan-ble-client
bundle exec rake test
```

Expected: `0 tests, 0 assertions, 0 failures, 0 errors`.

- [ ] **Step 5: Commit**

```bash
git add pc/stackchan-ble-client/
git commit -m "feat(ble-client): bootstrap pc/stackchan-ble-client gem skeleton"
```

---

## Task 2: FaceTable + LedColorTable constants

**Files:**
- Modify: `pc/stackchan-ble-client/lib/stackchan_ble_client/face_table.rb`
- Modify: `pc/stackchan-ble-client/lib/stackchan_ble_client/led_color_table.rb`
- Create: `pc/stackchan-ble-client/test/face_table_test.rb`
- Create: `pc/stackchan-ble-client/test/led_color_table_test.rb`

- [ ] **Step 1: Write failing tests for FaceTable**

`pc/stackchan-ble-client/test/face_table_test.rb`:

```ruby
require "test_helper"

class FaceTableTest < Test::Unit::TestCase
  def test_neutral_index_is_zero
    assert_equal "0", StackchanBleClient::FaceTable::FACE_INDICES.fetch(:neutral)
  end

  def test_smile_index_is_one
    assert_equal "1", StackchanBleClient::FaceTable::FACE_INDICES.fetch(:smile)
  end

  def test_joy_index_is_two
    assert_equal "2", StackchanBleClient::FaceTable::FACE_INDICES.fetch(:joy)
  end

  def test_surprised_index_is_three
    assert_equal "3", StackchanBleClient::FaceTable::FACE_INDICES.fetch(:surprised)
  end

  def test_unknown_face_raises_key_error
    assert_raise(KeyError) do
      StackchanBleClient::FaceTable::FACE_INDICES.fetch(:bogus)
    end
  end
end
```

- [ ] **Step 2: Write failing tests for LedColorTable**

`pc/stackchan-ble-client/test/led_color_table_test.rb`:

```ruby
require "test_helper"

class LedColorTableTest < Test::Unit::TestCase
  def test_red_rgb
    assert_equal [255, 0, 0], StackchanBleClient::LedColorTable::LED_COLORS.fetch(:red)
  end

  def test_white_rgb
    assert_equal [255, 255, 255], StackchanBleClient::LedColorTable::LED_COLORS.fetch(:white)
  end

  def test_off_is_black
    assert_equal [0, 0, 0], StackchanBleClient::LedColorTable::LED_COLORS.fetch(:off)
  end

  def test_keys_are_symbols
    assert_true StackchanBleClient::LedColorTable::LED_COLORS.keys.all? { |k| k.is_a?(Symbol) }
  end

  def test_unknown_color_raises_key_error
    assert_raise(KeyError) do
      StackchanBleClient::LedColorTable::LED_COLORS.fetch(:bogus)
    end
  end
end
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `cd pc/stackchan-ble-client && bundle exec rake test`
Expected: 10 failures with `KeyError` on every assertion (`FACE_INDICES` / `LED_COLORS` not defined under the new namespace).

- [ ] **Step 4: Implement FaceTable**

`pc/stackchan-ble-client/lib/stackchan_ble_client/face_table.rb`:

```ruby
module StackchanBleClient
  module FaceTable
    FACE_INDICES = {
      neutral:   "0",
      smile:     "1",
      joy:       "2",
      surprised: "3",
    }.freeze
  end
end
```

- [ ] **Step 5: Implement LedColorTable**

`pc/stackchan-ble-client/lib/stackchan_ble_client/led_color_table.rb`:

```ruby
module StackchanBleClient
  module LedColorTable
    LED_COLORS = {
      red:     [255, 0,   0],
      green:   [0,   255, 0],
      blue:    [0,   0,   255],
      yellow:  [255, 255, 0],
      cyan:    [0,   255, 255],
      magenta: [255, 0,   255],
      white:   [255, 255, 255],
      off:     [0,   0,   0],
    }.freeze
  end
end
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `cd pc/stackchan-ble-client && bundle exec rake test`
Expected: 10 tests pass, 0 failures.

- [ ] **Step 7: Commit**

```bash
git add pc/stackchan-ble-client/lib/stackchan_ble_client/face_table.rb pc/stackchan-ble-client/lib/stackchan_ble_client/led_color_table.rb pc/stackchan-ble-client/test/face_table_test.rb pc/stackchan-ble-client/test/led_color_table_test.rb
git commit -m "feat(ble-client): add FaceTable + LedColorTable constants"
```

---

## Task 3: FrameCodec (encode + ACK decode)

**Files:**
- Modify: `pc/stackchan-ble-client/lib/stackchan_ble_client/frame_codec.rb`
- Create: `pc/stackchan-ble-client/test/frame_codec_test.rb`

- [ ] **Step 1: Write failing tests**

`pc/stackchan-ble-client/test/frame_codec_test.rb`:

```ruby
require "test_helper"

class FrameCodecEncodeFaceTest < Test::Unit::TestCase
  def test_encode_face_neutral
    assert_equal "<F:0>\n", StackchanBleClient::FrameCodec.encode_face(face_name: :neutral)
  end

  def test_encode_face_joy
    assert_equal "<F:2>\n", StackchanBleClient::FrameCodec.encode_face(face_name: :joy)
  end

  def test_encode_face_unknown_raises
    assert_raise(KeyError) do
      StackchanBleClient::FrameCodec.encode_face(face_name: :bogus)
    end
  end
end

class FrameCodecEncodeLedTest < Test::Unit::TestCase
  def test_encode_led_both_red_solid
    assert_equal "<L:1,R:255,G:0,B:0,S:B,M:s>\n",
                 StackchanBleClient::FrameCodec.encode_led(r: 255, g: 0, b: 0, side: :both, mode: :solid)
  end

  def test_encode_led_left_blue_blink
    assert_equal "<L:1,R:0,G:0,B:255,S:L,M:b>\n",
                 StackchanBleClient::FrameCodec.encode_led(r: 0, g: 0, b: 255, side: :left, mode: :blink)
  end

  def test_encode_led_right_yellow_breathing
    assert_equal "<L:1,R:255,G:255,B:0,S:R,M:p>\n",
                 StackchanBleClient::FrameCodec.encode_led(r: 255, g: 255, b: 0, side: :right, mode: :breathing)
  end

  def test_encode_led_off_includes_rgb_as_zeros
    assert_equal "<L:1,R:0,G:0,B:0,S:B,M:o>\n",
                 StackchanBleClient::FrameCodec.encode_led(r: 0, g: 0, b: 0, side: :both, mode: :off)
  end

  def test_encode_led_unknown_side_raises
    assert_raise(ArgumentError) do
      StackchanBleClient::FrameCodec.encode_led(r: 0, g: 0, b: 0, side: :up, mode: :solid)
    end
  end

  def test_encode_led_unknown_mode_raises
    assert_raise(ArgumentError) do
      StackchanBleClient::FrameCodec.encode_led(r: 0, g: 0, b: 0, side: :both, mode: :strobe)
    end
  end
end

class FrameCodecAckTest < Test::Unit::TestCase
  def test_ack_ok_byte
    assert_equal :ok, StackchanBleClient::FrameCodec.parse_ack(".")
  end

  def test_ack_error_byte
    assert_equal :error, StackchanBleClient::FrameCodec.parse_ack("?")
  end

  def test_unknown_ack_byte_raises
    assert_raise(ArgumentError) do
      StackchanBleClient::FrameCodec.parse_ack("X")
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd pc/stackchan-ble-client && bundle exec rake test`
Expected: all FrameCodec tests fail (`NoMethodError` for `.encode_face` / `.encode_led` / `.parse_ack` under the stub module from Task 1).

- [ ] **Step 3: Implement FrameCodec**

`pc/stackchan-ble-client/lib/stackchan_ble_client/frame_codec.rb`:

```ruby
require_relative "face_table"

module StackchanBleClient
  module FrameCodec
    SIDE_TO_CHAR = {
      left:  "L",
      right: "R",
      both:  "B",
    }.freeze

    MODE_TO_CHAR = {
      solid:     "s",
      blink:     "b",
      breathing: "p",
      off:       "o",
    }.freeze

    ACK_OK    = "."
    ACK_ERROR = "?"

    module_function

    def encode_face(face_name:)
      index = FaceTable::FACE_INDICES.fetch(face_name)
      encode_pairs("F" => index)
    end

    def encode_led(r:, g:, b:, side:, mode:)
      side_char = SIDE_TO_CHAR.fetch(side) { raise ArgumentError, "unknown side: #{side.inspect}" }
      mode_char = MODE_TO_CHAR.fetch(mode) { raise ArgumentError, "unknown mode: #{mode.inspect}" }
      encode_pairs("L" => "1", "R" => r.to_s, "G" => g.to_s, "B" => b.to_s, "S" => side_char, "M" => mode_char)
    end

    def parse_ack(byte)
      case byte
      when ACK_OK    then :ok
      when ACK_ERROR then :error
      else
        raise ArgumentError, "unknown ack byte: #{byte.inspect}"
      end
    end

    def encode_pairs(pairs)
      "<" + pairs.map { |k, v| "#{k}:#{v}" }.join(",") + ">\n"
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd pc/stackchan-ble-client && bundle exec rake test`
Expected: 12 FrameCodec tests pass (in addition to Task 2's 10).

- [ ] **Step 5: Commit**

```bash
git add pc/stackchan-ble-client/lib/stackchan_ble_client/frame_codec.rb pc/stackchan-ble-client/test/frame_codec_test.rb
git commit -m "feat(ble-client): add FrameCodec encode_face/encode_led + parse_ack"
```

---

## Task 4: HsbToRgb conversion

**Files:**
- Modify: `pc/stackchan-ble-client/lib/stackchan_ble_client/hsb_to_rgb.rb`
- Create: `pc/stackchan-ble-client/test/hsb_to_rgb_test.rb`

- [ ] **Step 1: Write failing tests**

`pc/stackchan-ble-client/test/hsb_to_rgb_test.rb`:

```ruby
require "test_helper"

class HsbToRgbTest < Test::Unit::TestCase
  # H byte semantics: 0-255 maps linearly to 0-360°.
  # S/B bytes: 0-255 map linearly to 0-100%.

  def test_zero_brightness_is_black
    assert_equal [0, 0, 0], StackchanBleClient::HsbToRgb.convert(0x000000)
    assert_equal [0, 0, 0], StackchanBleClient::HsbToRgb.convert(0xFFFF00)
  end

  def test_zero_saturation_is_grayscale_at_brightness
    # full brightness, no saturation → white
    assert_equal [255, 255, 255], StackchanBleClient::HsbToRgb.convert(0xAA00FF)
    # half brightness, no saturation → mid-gray
    r, g, b = StackchanBleClient::HsbToRgb.convert(0xAA0080)
    assert_equal r, g
    assert_equal g, b
    assert_in_delta 128, r, 2
  end

  def test_pure_red_full_sat_full_bright
    # H=0 (red), S=255, B=255
    assert_equal [255, 0, 0], StackchanBleClient::HsbToRgb.convert(0x00FFFF)
  end

  def test_pure_green_full_sat_full_bright
    # H ≈ 120° → 120/360*256 ≈ 85
    r, g, b = StackchanBleClient::HsbToRgb.convert(0x55FFFF)
    assert_in_delta 0,   r, 6
    assert_in_delta 255, g, 6
    assert_in_delta 0,   b, 6
  end

  def test_pure_blue_full_sat_full_bright
    # H ≈ 240° → 240/360*256 ≈ 170
    r, g, b = StackchanBleClient::HsbToRgb.convert(0xAAFFFF)
    assert_in_delta 0,   r, 6
    assert_in_delta 0,   g, 6
    assert_in_delta 255, b, 6
  end

  def test_pure_yellow_full_sat_full_bright
    # H ≈ 60° → 60/360*256 ≈ 43
    r, g, b = StackchanBleClient::HsbToRgb.convert(0x2BFFFF)
    assert_in_delta 255, r, 6
    assert_in_delta 255, g, 6
    assert_in_delta 0,   b, 6
  end

  def test_returns_three_integers_in_0_255
    [0x00FFFF, 0x55FFFF, 0xAAFFFF, 0xFFFFFF, 0x80808080 & 0xFFFFFF, 0x12345678 & 0xFFFFFF].each do |packed|
      r, g, b = StackchanBleClient::HsbToRgb.convert(packed)
      [r, g, b].each do |v|
        assert_kind_of Integer, v
        assert_operator v, :>=, 0
        assert_operator v, :<=, 255
      end
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd pc/stackchan-ble-client && bundle exec rake test`
Expected: 7 HsbToRgb tests fail (`NoMethodError` on `.convert`).

- [ ] **Step 3: Implement HsbToRgb**

`pc/stackchan-ble-client/lib/stackchan_ble_client/hsb_to_rgb.rb`:

```ruby
module StackchanBleClient
  module HsbToRgb
    module_function

    # Convert a 24-bit packed HSB value (0xHHSSBB) to [r, g, b] each in 0..255.
    #
    #   HH = hue          0..255 mapped linearly to 0..360 degrees
    #   SS = saturation   0..255 mapped linearly to 0..1
    #   BB = brightness   0..255 mapped linearly to 0..1
    #
    # Uses the standard HSV → RGB algorithm (six 60° hexagon sectors).
    def convert(packed)
      h_byte = (packed >> 16) & 0xFF
      s_byte = (packed >> 8) & 0xFF
      b_byte = packed & 0xFF

      v = b_byte / 255.0
      s = s_byte / 255.0
      h = (h_byte / 255.0) * 360.0

      c = v * s
      h_prime = h / 60.0
      x = c * (1 - ((h_prime % 2) - 1).abs)

      r1, g1, b1 =
        case h_prime.to_i
        when 0 then [c, x, 0]
        when 1 then [x, c, 0]
        when 2 then [0, c, x]
        when 3 then [0, x, c]
        when 4 then [x, 0, c]
        else        [c, 0, x]
        end

      m = v - c
      [(r1 + m) * 255, (g1 + m) * 255, (b1 + m) * 255].map { |f| f.round.clamp(0, 255) }
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd pc/stackchan-ble-client && bundle exec rake test`
Expected: 7 HsbToRgb tests pass.

- [ ] **Step 5: Commit**

```bash
git add pc/stackchan-ble-client/lib/stackchan_ble_client/hsb_to_rgb.rb pc/stackchan-ble-client/test/hsb_to_rgb_test.rb
git commit -m "feat(ble-client): add HsbToRgb conversion"
```

---

## Task 5: SendBuilder DSL aggregator

**Files:**
- Modify: `pc/stackchan-ble-client/lib/stackchan_ble_client/send_builder.rb`
- Create: `pc/stackchan-ble-client/test/send_builder_test.rb`

The SendBuilder implements the `#send do |stackchan| ... end` block semantics from spec §4.3: `(method, side)` last-wins aggregation, first-occurrence ordering, max 4 frames (face / led_both / led_left / led_right).

- [ ] **Step 1: Write failing tests**

`pc/stackchan-ble-client/test/send_builder_test.rb`:

```ruby
require "test_helper"

class SendBuilderBasicTest < Test::Unit::TestCase
  def test_face_only
    b = StackchanBleClient::SendBuilder.new
    b.face(:joy)
    assert_equal ["<F:2>\n"], b.to_frames
  end

  def test_led_named_default_side_both_mode_solid
    b = StackchanBleClient::SendBuilder.new
    b.led(:red)
    assert_equal ["<L:1,R:255,G:0,B:0,S:B,M:s>\n"], b.to_frames
  end

  def test_led_named_with_mode
    b = StackchanBleClient::SendBuilder.new
    b.led(:blue, mode: :blink)
    assert_equal ["<L:1,R:0,G:0,B:255,S:B,M:b>\n"], b.to_frames
  end

  def test_led_named_with_side
    b = StackchanBleClient::SendBuilder.new
    b.led(:green, side: :left)
    assert_equal ["<L:1,R:0,G:255,B:0,S:L,M:s>\n"], b.to_frames
  end

  def test_led_rgb_form
    b = StackchanBleClient::SendBuilder.new
    b.led(:rgb, 0xFF8000)
    assert_equal ["<L:1,R:255,G:128,B:0,S:B,M:s>\n"], b.to_frames
  end

  def test_led_hsb_form_red
    b = StackchanBleClient::SendBuilder.new
    b.led(:hsb, 0x00FFFF) # H=0, S=255, B=255 → pure red
    assert_equal ["<L:1,R:255,G:0,B:0,S:B,M:s>\n"], b.to_frames
  end
end

class SendBuilderAggregationTest < Test::Unit::TestCase
  def test_same_method_same_side_last_wins
    b = StackchanBleClient::SendBuilder.new
    b.led(:red)
    b.led(:blue)        # both → blue
    assert_equal ["<L:1,R:0,G:0,B:255,S:B,M:s>\n"], b.to_frames
  end

  def test_different_sides_independent
    b = StackchanBleClient::SendBuilder.new
    b.led(:red,   side: :left)
    b.led(:blue,  side: :right)
    assert_equal [
      "<L:1,R:255,G:0,B:0,S:L,M:s>\n",
      "<L:1,R:0,G:0,B:255,S:R,M:s>\n",
    ], b.to_frames
  end

  def test_face_and_led_in_order_of_first_appearance
    b = StackchanBleClient::SendBuilder.new
    b.face(:joy)
    b.led(:red)
    b.led(:blue)
    assert_equal [
      "<F:2>\n",
      "<L:1,R:0,G:0,B:255,S:B,M:s>\n",
    ], b.to_frames
  end

  def test_led_first_then_face_preserves_first_occurrence_order
    b = StackchanBleClient::SendBuilder.new
    b.led(:red)
    b.face(:smile)
    assert_equal [
      "<L:1,R:255,G:0,B:0,S:B,M:s>\n",
      "<F:1>\n",
    ], b.to_frames
  end

  def test_max_4_frames
    b = StackchanBleClient::SendBuilder.new
    b.face(:joy)
    b.led(:red,  side: :both)
    b.led(:blue, side: :left)
    b.led(:green, side: :right)
    # add more — should not exceed 4
    b.face(:smile)
    b.led(:white, side: :both, mode: :blink)
    frames = b.to_frames
    assert_equal 4, frames.size
    assert_includes frames, "<F:1>\n"
    assert_includes frames, "<L:1,R:255,G:255,B:255,S:B,M:b>\n"
    assert_includes frames, "<L:1,R:0,G:0,B:255,S:L,M:s>\n"
    assert_includes frames, "<L:1,R:0,G:255,B:0,S:R,M:s>\n"
  end

  def test_form_can_switch_with_last_wins
    b = StackchanBleClient::SendBuilder.new
    b.led(:red)
    b.led(:rgb, 0xFF8000)  # overrides
    assert_equal ["<L:1,R:255,G:128,B:0,S:B,M:s>\n"], b.to_frames
  end

  def test_unknown_form_raises
    b = StackchanBleClient::SendBuilder.new
    assert_raise(ArgumentError) do
      b.led(:not_a_form, 0x123456)
      b.to_frames
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd pc/stackchan-ble-client && bundle exec rake test`
Expected: 14 SendBuilder tests fail (`NoMethodError` on `.new` / `face` / `led` / `to_frames`).

- [ ] **Step 3: Implement SendBuilder**

`pc/stackchan-ble-client/lib/stackchan_ble_client/send_builder.rb`:

```ruby
require_relative "face_table"
require_relative "led_color_table"
require_relative "frame_codec"
require_relative "hsb_to_rgb"

module StackchanBleClient
  class SendBuilder
    def initialize
      @commands = {}   # key → command hash
      @order    = []   # first-occurrence ordering of keys
    end

    def face(name)
      record(:face, { kind: :face, name: name })
    end

    def led(form, value = nil, side: :both, mode: :solid)
      record([:led, side], { kind: :led, form: form, value: value, side: side, mode: mode })
    end

    def to_frames
      @order.map { |key| encode(@commands.fetch(key)) }
    end

    private

    def record(key, params)
      @order << key unless @commands.key?(key)
      @commands[key] = params
    end

    def encode(cmd)
      case cmd[:kind]
      when :face
        FrameCodec.encode_face(face_name: cmd[:name])
      when :led
        r, g, b = resolve_color(cmd[:form], cmd[:value])
        FrameCodec.encode_led(r: r, g: g, b: b, side: cmd[:side], mode: cmd[:mode])
      end
    end

    def resolve_color(form, value)
      case form
      when :rgb
        [(value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF]
      when :hsb
        HsbToRgb.convert(value)
      when Symbol
        LedColorTable::LED_COLORS.fetch(form) do
          raise ArgumentError, "unknown LED form / named color: #{form.inspect}"
        end
      else
        raise ArgumentError, "LED form must be a Symbol, got #{form.inspect}"
      end
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd pc/stackchan-ble-client && bundle exec rake test`
Expected: 14 SendBuilder tests pass.

- [ ] **Step 5: Commit**

```bash
git add pc/stackchan-ble-client/lib/stackchan_ble_client/send_builder.rb pc/stackchan-ble-client/test/send_builder_test.rb
git commit -m "feat(ble-client): SendBuilder DSL aggregator (last-wins + first-occurrence ordering)"
```

---

## Task 6: Client class (connect / send / disconnect) + fake-transport test

**Files:**
- Modify: `pc/stackchan-ble-client/lib/stackchan_ble_client/client.rb`
- Create: `pc/stackchan-ble-client/test/client_test.rb`

Client wraps `corebluetooth_mac` and exposes connect / send / disconnect. For testability the transport is injectable: when `transport:` is nil (default), Client wires up a real `CoreBluetoothMac::Central`. When `transport:` is provided (test only), Client uses that object instead. The transport's contract is small (open/close/scan/connect/discover/find_characteristic + write_without_response/subscribe/unsubscribe), which the fake test transport implements directly.

- [ ] **Step 1: Write failing tests**

`pc/stackchan-ble-client/test/client_test.rb`:

```ruby
require "test_helper"

# Fake transport that imitates corebluetooth_mac's surface enough for Client tests.
class FakeTransport
  attr_reader :writes, :state, :closed, :scan_calls, :connect_calls
  attr_accessor :scan_result, :ack_replies

  def initialize
    @state         = :idle
    @writes        = []
    @scan_calls    = []
    @connect_calls = []
    @ack_replies   = [".", ".", ".", "."]  # default: 4 OKs for max-4-frame send
    @closed        = false
    @rx_char = FakeChar.new(:rx, self)
    @tx_char = FakeChar.new(:tx, self)
  end

  def scan(name:, timeout:)
    @scan_calls << [name, timeout]
    [FakeDevice.new(@scan_result || name)]
  end

  def connect(_device, timeout:)
    @connect_calls << timeout
    @state = :connected
    FakePeripheral.new(@rx_char, @tx_char)
  end

  def disconnect(_peripheral)
    @state = :disconnected
  end

  def close
    @closed = true
  end

  # Called by Client when it write_without_response on RX. Consumes one ack reply.
  def record_write(payload)
    @writes << payload
    @tx_char.deliver(@ack_replies.shift || ".")
  end
end

class FakeDevice
  attr_reader :name, :identifier, :rssi
  def initialize(name)
    @name = name
    @identifier = "FAKE-#{name}"
    @rssi = -50
  end
end

class FakePeripheral
  def initialize(rx, tx)
    @rx = rx
    @tx = tx
  end

  def discover_services(timeout:); end
  def services; []; end
  def find_characteristic(uuid)
    case uuid.downcase
    when "6e400002-b5a3-f393-e0a9-e50e24dcca9e" then @rx
    when "6e400003-b5a3-f393-e0a9-e50e24dcca9e" then @tx
    else nil
    end
  end
end

class FakeChar
  def initialize(kind, transport)
    @kind = kind
    @transport = transport
    @subscription = nil
  end

  def write_without_response(payload)
    @transport.record_write(payload)
  end

  def subscribe
    @subscription = FakeSubscription.new
  end

  def unsubscribe
    @subscription = nil
  end

  def deliver(value)
    @subscription&.push(value)
  end
end

class FakeSubscription
  def initialize
    @queue = []
  end

  def push(value)
    @queue << value
  end

  def next_value(timeout:)
    @queue.shift  # ignore timeout — fake delivers synchronously
  end
end

class ClientConnectTest < Test::Unit::TestCase
  def setup
    @transport = FakeTransport.new
    @client = StackchanBleClient::Client.new(
      device_name: "StackChan-PicoRuby",
      transport:   @transport,
    )
  end

  def test_connect_scans_for_device_name
    @client.connect
    assert_equal [["StackChan-PicoRuby", 10.0]], @transport.scan_calls
  end

  def test_connect_records_connect_call
    @client.connect
    assert_equal 1, @transport.connect_calls.size
  end

  def test_disconnect_closes_transport
    @client.connect
    @client.disconnect
    assert_equal :disconnected, @transport.state
    assert_true @transport.closed
  end
end

class ClientSendTest < Test::Unit::TestCase
  def setup
    @transport = FakeTransport.new
    @client = StackchanBleClient::Client.new(
      device_name: "StackChan-PicoRuby",
      transport:   @transport,
    )
    @client.connect
  end

  def test_send_face_only_sends_one_frame
    @client.send do |s|
      s.face(:joy)
    end
    assert_equal ["<F:2>\n"], @transport.writes
  end

  def test_send_led_both_named_one_frame
    @client.send do |s|
      s.led(:red, mode: :blink)
    end
    assert_equal ["<L:1,R:255,G:0,B:0,S:B,M:b>\n"], @transport.writes
  end

  def test_send_combo_face_and_led_sends_two_frames_in_order
    @client.send do |s|
      s.face(:joy)
      s.led(:red, mode: :blink)
    end
    assert_equal [
      "<F:2>\n",
      "<L:1,R:255,G:0,B:0,S:B,M:b>\n",
    ], @transport.writes
  end

  def test_send_raises_device_error_when_ack_is_question_mark
    @transport.ack_replies = ["?"]
    assert_raise(StackchanBleClient::DeviceError) do
      @client.send do |s|
        s.face(:joy)
      end
    end
  end

  def test_send_propagates_partial_failure_after_first_ok
    @transport.ack_replies = [".", "?"]
    assert_raise(StackchanBleClient::DeviceError) do
      @client.send do |s|
        s.face(:joy)
        s.led(:red)
      end
    end
    # both writes were attempted
    assert_equal 2, @transport.writes.size
  end

  def test_send_4_frames_in_left_right_combo
    @client.send do |s|
      s.face(:joy)
      s.led(:red,  side: :both)
      s.led(:blue, side: :left)
      s.led(:green, side: :right, mode: :breathing)
    end
    assert_equal 4, @transport.writes.size
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd pc/stackchan-ble-client && bundle exec rake test`
Expected: 9 Client tests fail (`NoMethodError` on `.new` etc).

- [ ] **Step 3: Implement Client**

`pc/stackchan-ble-client/lib/stackchan_ble_client/client.rb`:

```ruby
require_relative "send_builder"
require_relative "frame_codec"

module StackchanBleClient
  class Client
    NUS_RX_CHAR = "6e400002-b5a3-f393-e0a9-e50e24dcca9e"
    NUS_TX_CHAR = "6e400003-b5a3-f393-e0a9-e50e24dcca9e"

    def initialize(device_name:, scan_timeout: 10.0, connect_timeout: 5.0, ack_timeout: 3.0, transport: nil)
      @device_name     = device_name
      @scan_timeout    = scan_timeout
      @connect_timeout = connect_timeout
      @ack_timeout     = ack_timeout
      @transport       = transport || build_default_transport
      @peripheral      = nil
      @rx_char         = nil
      @tx_char         = nil
      @subscription    = nil
    end

    def connect
      devices = @transport.scan(name: @device_name, timeout: @scan_timeout)
      raise ConnectionError, "no device named #{@device_name.inspect}" if devices.empty?
      @peripheral = @transport.connect(devices.first, timeout: @connect_timeout)
      @peripheral.discover_services(timeout: @connect_timeout)
      @peripheral.services.each { |svc| svc.discover_characteristics(timeout: @connect_timeout) if svc.respond_to?(:discover_characteristics) }
      @rx_char = @peripheral.find_characteristic(NUS_RX_CHAR) or raise ConnectionError, "NUS RX not found"
      @tx_char = @peripheral.find_characteristic(NUS_TX_CHAR) or raise ConnectionError, "NUS TX not found"
      @subscription = @tx_char.subscribe
      self
    end

    def send(&block)
      raise ConnectionError, "not connected" unless @subscription
      builder = SendBuilder.new
      block.call(builder)
      builder.to_frames.each { |frame| send_frame(frame) }
      self
    end

    def disconnect
      @tx_char&.unsubscribe
      @transport.disconnect(@peripheral) if @peripheral
      @transport.close
      @peripheral = @rx_char = @tx_char = @subscription = nil
      self
    end

    private

    def send_frame(frame)
      @rx_char.write_without_response(frame)
      ack = @subscription.next_value(timeout: @ack_timeout)
      raise TimeoutError, "ACK timeout for frame #{frame.inspect}" if ack.nil?
      case FrameCodec.parse_ack(ack)
      when :ok    then nil
      when :error then raise DeviceError, "device rejected frame #{frame.inspect}"
      end
    end

    def build_default_transport
      require "corebluetooth_mac"
      CoreBluetoothMac::Central.new
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd pc/stackchan-ble-client && bundle exec rake test`
Expected: 9 Client tests pass.

- [ ] **Step 5: Commit**

```bash
git add pc/stackchan-ble-client/lib/stackchan_ble_client/client.rb pc/stackchan-ble-client/test/client_test.rb
git commit -m "feat(ble-client): Client connect/send/disconnect (with injectable transport)"
```

---

## Task 7: `stackchan-ble-control` CLI exe

**Files:**
- Create: `pc/stackchan-ble-client/exe/stackchan-ble-control`

The CLI is a thin OptionParser wrapper that builds a SendBuilder block and shells to Client. Exit codes per spec §4.5 (0/2/3/4/5/9). Each sub-command corresponds to one or two SendBuilder calls.

- [ ] **Step 1: Create CLI exe**

`pc/stackchan-ble-client/exe/stackchan-ble-control`:

```ruby
#!/usr/bin/env ruby
# frozen_string_literal: true

require "bundler/setup"
require "optparse"
require "stackchan_ble_client"

EXIT_OK         = 0
EXIT_ADAPTER    = 2
EXIT_TIMEOUT    = 3
EXIT_CONNECTION = 4
EXIT_ASSERTION  = 5
EXIT_UNCAT      = 9

device_name = ENV.fetch("BLE_DEVICE_NAME", "StackChan-PicoRuby")
side        = :both
mode        = :solid

parser = OptionParser.new do |opts|
  opts.on("--device NAME") { |v| device_name = v }
  opts.on("--side SIDE") do |v|
    side = v.to_sym
    abort "error: --side must be left/right/both" unless %i[left right both].include?(side)
  end
  opts.on("--mode MODE") do |v|
    mode = v.to_sym
    abort "error: --mode must be solid/blink/breathing/off" unless %i[solid blink breathing off].include?(mode)
  end
  opts.on("--face NAME")  { |v| $combo_face  = v.to_sym }
  opts.on("--led SPEC")   { |v| $combo_led   = v }   # "<color> <mode>" e.g. "red blink"
end
parser.parse!(ARGV)

command = ARGV.shift
abort "error: command required (face / led / led-rgb / led-hsb / combo / raw)" unless command

client = StackchanBleClient::Client.new(device_name: device_name)

begin
  client.connect

  case command
  when "face"
    name = ARGV.shift or abort "error: face requires <name>"
    client.send { |s| s.face(name.to_sym) }
  when "led"
    color = ARGV.shift or abort "error: led requires <color>"
    color_mode = ARGV.shift  # optional positional mode override
    effective_mode = color_mode ? color_mode.to_sym : mode
    client.send { |s| s.led(color.to_sym, side: side, mode: effective_mode) }
  when "led-rgb"
    hex = ARGV.shift or abort "error: led-rgb requires <hex>"
    val = Integer(hex, 16)
    client.send { |s| s.led(:rgb, val, side: side, mode: mode) }
  when "led-hsb"
    hex = ARGV.shift or abort "error: led-hsb requires <hex>"
    val = Integer(hex, 16)
    client.send { |s| s.led(:hsb, val, side: side, mode: mode) }
  when "combo"
    face_name = $combo_face or abort "error: combo requires --face <name>"
    led_spec  = $combo_led  or abort "error: combo requires --led '<color> <mode>'"
    led_color, led_mode = led_spec.split(/\s+/, 2)
    client.send do |s|
      s.face(face_name)
      s.led(led_color.to_sym, side: side, mode: (led_mode || "solid").to_sym)
    end
  when "raw"
    frame = ARGV.shift or abort "error: raw requires <frame>"
    frame += "\n" unless frame.end_with?("\n")
    # raw bypasses SendBuilder — write directly via internal API. For Phase 3
    # we expose a public Client#raw_send for completeness.
    client.raw_send(frame)
  else
    abort "error: unknown command #{command.inspect}"
  end

  exit EXIT_OK
rescue StackchanBleClient::TimeoutError => e
  warn "[FAIL] reason=#{e.message} domain=timeout"
  exit EXIT_TIMEOUT
rescue StackchanBleClient::ConnectionError => e
  warn "[FAIL] reason=#{e.message} domain=connection"
  exit EXIT_CONNECTION
rescue StackchanBleClient::DeviceError => e
  warn "[FAIL] reason=#{e.message} domain=assertion"
  exit EXIT_ASSERTION
rescue StackchanBleClient::Error => e
  warn "[FAIL] reason=#{e.message} domain=ble-client"
  exit EXIT_UNCAT
rescue => e
  warn "[FAIL] reason=#{e.class}: #{e.message} domain=uncaught"
  exit EXIT_UNCAT
ensure
  begin
    client.disconnect
  rescue
    # already in error path, suppress
  end
end
```

- [ ] **Step 2: Add `Client#raw_send` for the `raw` sub-command**

Edit `pc/stackchan-ble-client/lib/stackchan_ble_client/client.rb` — add this public method right after `def send`:

```ruby
    def raw_send(frame_string)
      raise ConnectionError, "not connected" unless @subscription
      send_frame(frame_string)
      self
    end
```

(`send_frame` is the private helper already defined.)

- [ ] **Step 3: Make the exe executable**

```bash
chmod +x pc/stackchan-ble-client/exe/stackchan-ble-control
```

- [ ] **Step 4: Verify exe loads (smoke-only, no BLE)**

Run:

```bash
cd pc/stackchan-ble-client && bundle exec exe/stackchan-ble-control --help 2>&1 | head -20
```

Expected: optparse banner / no syntax error. (The `--help` will hit OptionParser's default behavior — if optparse doesn't auto-print help, it will instead error out on `command required` which is also fine; the point is "no Ruby load error".)

- [ ] **Step 5: Commit**

```bash
git add pc/stackchan-ble-client/exe/stackchan-ble-control pc/stackchan-ble-client/lib/stackchan_ble_client/client.rb
git commit -m "feat(ble-client): add stackchan-ble-control CLI exe with sub-commands"
```

---

## Task 8: `lib/deploy/picomodem.rb` module

**Files:**
- Create: `lib/deploy/picomodem.rb` (at project root, NOT inside the gem)

Port the logic from `pc/stackchan-protocol/exe/picomodem-upload` into a Ruby module callable from Rakefile. The CLI is kept simple: one `Deploy::Picomodem.upload(src:, dst:, port:)` method that wraps the entire handshake → STX → FILE_WRITE → CHUNK loop.

- [ ] **Step 1: Create the deploy module**

`lib/deploy/picomodem.rb`:

```ruby
# frozen_string_literal: true

# PicoModem file uploader for R2P2 (PicoRuby shell). Ported from
# pc/stackchan-protocol/exe/picomodem-upload as part of Phase 3 (2026-05-17);
# the gem is being retired so the upload logic now lives at the project root
# as a Rakefile-callable Ruby module.
#
# See the original exe header (still in git history as of Phase 2) for the
# rationale on the handshake-responder phase.

require "uart"

module Deploy
  module Picomodem
    STX        = 0x02
    FILE_WRITE = 0x02
    CHUNK      = 0x04
    FILE_ACK   = 0x82
    CHUNK_ACK  = 0x84
    DONE_ACK   = 0x8F
    CHUNK_SIZE = 480

    CURSOR_QUERY = "\e[6n"
    CURSOR_REPLY = "\e[1;1R"
    DSR_QUERY    = "\e[5n"
    DSR_REPLY    = "\e[0n"

    DEFAULT_HANDSHAKE_SECONDS = 8.0

    module_function

    def upload(src:, dst:, port:, baud: 115_200,
               handshake_seconds: DEFAULT_HANDSHAKE_SECONDS, stdout: $stdout)
      content = File.binread(src)
      stdout.puts "[picomodem] src=#{src} dst=#{dst} port=#{port} size=#{content.bytesize}"

      UART.open(port, baud) do |serial|
        run_handshake_responder(serial, handshake_seconds, stdout)
        drain(serial)

        # Single STX byte triggers PicoModem.session on the shell side.
        serial.write [STX].pack("C")
        sleep 0.05

        payload = [content.bytesize].pack("N") + dst
        serial.write make_frame(FILE_WRITE, payload)

        frame = recv_frame(serial, timeout: 5.0)
        unless frame && frame[0] == FILE_ACK
          raise "[picomodem] FILE_ACK expected, got #{frame.inspect}"
        end
        stdout.puts "[picomodem] FILE_ACK READY"

        offset = 0
        while offset < content.bytesize
          chunk = content.byteslice(offset, CHUNK_SIZE)
          serial.write make_frame(CHUNK, chunk)
          ack = recv_frame(serial, timeout: 5.0)
          unless ack && ack[0] == CHUNK_ACK
            raise "[picomodem] CHUNK_ACK expected at offset=#{offset}, got #{ack.inspect}"
          end
          offset += chunk.bytesize
          stdout.print "."
          stdout.flush
        end
        stdout.puts

        done = recv_frame(serial, timeout: 5.0)
        unless done && done[0] == DONE_ACK
          raise "[picomodem] DONE_ACK expected, got #{done.inspect}"
        end
        stdout.puts "[picomodem] DONE_ACK ok"
      end
      true
    end

    def crc16(data, crc = 0xFFFF)
      data.each_byte do |b|
        crc ^= b << 8
        8.times do
          crc = (crc & 0x8000) != 0 ? ((crc << 1) ^ 0x1021) & 0xFFFF : (crc << 1) & 0xFFFF
        end
      end
      crc
    end

    def make_frame(cmd, payload = "")
      body = [cmd].pack("C") + payload.b
      [STX, body.bytesize].pack("Cn") + body + [crc16(body)].pack("n")
    end

    def read_exact(io, n, timeout: 5.0)
      buf = +""
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      while buf.bytesize < n
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        return nil if remaining <= 0
        return nil unless io.wait_readable(remaining)
        chunk = io.read(n - buf.bytesize)
        return nil if chunk.nil? || chunk.empty?
        buf << chunk
      end
      buf
    end

    def recv_frame(io, timeout: 5.0)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      loop do
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        return nil if remaining <= 0
        b = read_exact(io, 1, timeout: remaining)
        return nil unless b
        break if b.bytes[0] == STX
      end
      len_bytes = read_exact(io, 2, timeout: timeout)
      return nil unless len_bytes
      length = len_bytes.unpack1("n")
      rest = read_exact(io, length + 2, timeout: timeout)
      return nil unless rest
      body     = rest.byteslice(0, length)
      expected = rest.byteslice(length, 2).unpack1("n")
      return nil unless crc16(body) == expected
      [body.getbyte(0), body.byteslice(1, length - 1) || ""]
    end

    def run_handshake_responder(serial, duration, stdout)
      stop = false
      cursor_replies = 0
      dsr_replies    = 0
      buf = +""
      thr = Thread.new do
        while !stop
          if serial.wait_readable(0.05)
            begin
              chunk = serial.read_nonblock(256)
              buf << chunk if chunk && !chunk.empty?
              while (i = buf.index(CURSOR_QUERY))
                buf.slice!(0, i + CURSOR_QUERY.bytesize)
                serial.write CURSOR_REPLY
                cursor_replies += 1
              end
              while (i = buf.index(DSR_QUERY))
                buf.slice!(0, i + DSR_QUERY.bytesize)
                serial.write DSR_REPLY
                dsr_replies += 1
              end
              buf.slice!(0, buf.bytesize - 64) if buf.bytesize > 1024
            rescue IO::WaitReadable, EOFError
              # transient
            end
          end
        end
      end
      stdout.puts "[picomodem] handshake phase: #{duration}s (answers \\e[6n / \\e[5n so editor unblocks)"
      sleep duration
      stop = true
      thr.join
      stdout.puts "[picomodem] handshake done: cursor_replies=#{cursor_replies} dsr_replies=#{dsr_replies}"
    end

    def drain(serial)
      while serial.wait_readable(0.1)
        begin
          drained = serial.read_nonblock(256)
          break if drained.nil? || drained.empty?
        rescue IO::WaitReadable, EOFError
          break
        end
      end
    end
  end
end
```

- [ ] **Step 2: Verify Ruby loads the module**

Run from project root:

```bash
ruby -Ilib -r deploy/picomodem -e 'puts Deploy::Picomodem.respond_to?(:upload)'
```

Expected: `true` (and no LoadError on `uart` — if uart isn't on the system load path, the Rakefile will need `bundle exec`; defer to Task 9 wiring).

- [ ] **Step 3: Commit**

```bash
git add lib/deploy/picomodem.rb
git commit -m "feat(deploy): extract picomodem-upload logic into lib/deploy/picomodem.rb module"
```

---

## Task 9: Rakefile — refactor `r2p2:upload` / `r2p2:upload_mrb` to use `Deploy::Picomodem`

**Files:**
- Modify: `Rakefile`

- [ ] **Step 1: Edit Rakefile**

At the top of `Rakefile`, after the existing `require`/constants section (before `namespace :r2p2 do`), add:

```ruby
require_relative "lib/deploy/picomodem"
```

`uart` gem needs to be on the Rakefile's load path. Add a bundler shim at the very top of `Rakefile`:

```ruby
require "bundler/setup" if File.exist?(File.expand_path("Gemfile", __dir__))
```

If a project-root `Gemfile` doesn't exist (the existing layout has gemfiles only inside `pc/stackchan-protocol/` and now `pc/stackchan-ble-client/`), create one at project root with just `uart` so the Rakefile can pick it up:

`Gemfile` (project root, only if not already present):

```ruby
source "https://rubygems.org"

gem "uart"
```

Then:

```bash
bundle install
```

Replace the `r2p2:upload` task (currently lines 117-126) with:

```ruby
  desc 'upload a Ruby file via PicoModem (SRC=path DST=/home/foo.rb), defaults to examples/app.rb'
  task :upload do
    src  = ENV.fetch('SRC', 'mrbgems/picoruby-stackchan-protocol/examples/app.rb')
    dst  = ENV.fetch('DST', '/home/app.rb')
    port = espport
    abs_src = File.expand_path(src, __dir__)
    Deploy::Picomodem.upload(src: abs_src, dst: dst, port: port)
  end
```

Replace the `r2p2:upload_mrb` task (currently lines 128-158) with:

```ruby
  desc 'host-compile SRC=path/to/foo.rb to .mrb and upload as /home/app.mrb (autostart bytecode path; bypasses on-device compile)'
  task :upload_mrb do
    src = ENV.fetch('SRC') { abort 'SRC=path/to/file.rb is required for r2p2:upload_mrb' }
    src_path = File.expand_path(src, __dir__)
    abort "SRC not found: #{src_path}" unless File.exist?(src_path)

    picorbc = "#{R2P2_ROOT}/components/picoruby-esp32/picoruby/bin/picorbc"
    unless File.executable?(picorbc)
      abort "picorbc not found at #{picorbc} — run `rake r2p2:setup` first (host picoruby build)"
    end

    build_dir = File.expand_path('tmp/build', __dir__)
    mkdir_p build_dir
    base = File.basename(src_path, File.extname(src_path))
    mrb_path = File.join(build_dir, "#{base}.mrb")
    rm_f mrb_path
    sh picorbc, '-o', mrb_path, src_path
    abort "picorbc produced no output at #{mrb_path}" unless File.exist?(mrb_path)
    puts "[upload_mrb] compiled #{src} -> #{mrb_path} (#{File.size(mrb_path)} bytes)"

    port = espport
    Deploy::Picomodem.upload(src: mrb_path, dst: '/home/app.mrb', port: port)
  end
```

- [ ] **Step 2: Verify Rakefile loads cleanly**

Run from project root:

```bash
bundle exec rake -T r2p2: 2>&1 | head -20
```

Expected: r2p2 task list prints. No LoadError. If `uart` is missing, run `bundle install` first.

- [ ] **Step 3: Commit**

```bash
git add Rakefile Gemfile Gemfile.lock
git commit -m "refactor(rakefile): use Deploy::Picomodem inline instead of pc/stackchan-protocol exe"
```

---

## Task 10: Rakefile — delete legacy USB-serial tasks

**Files:**
- Modify: `Rakefile`

- [ ] **Step 1: Delete the four legacy task blocks**

From `Rakefile`, delete (in their entirety):

* `r2p2:send_led` (currently lines 160-168)
* `r2p2:send_face` (currently lines 170-177)
* `r2p2:verify_led` (currently lines 179-209)
* `r2p2:ble_verify` (currently lines 211-227)

(Line numbers are pre-Task-9; after that refactor the line numbers shift but the four `desc`/`task` blocks remain identifiable by name.)

- [ ] **Step 2: Verify Rakefile still loads**

Run from project root:

```bash
bundle exec rake -T r2p2: 2>&1
```

Expected: remaining tasks are `r2p2:build`, `r2p2:build_flash`, `r2p2:capture`, `r2p2:flash`, `r2p2:monitor`, `r2p2:rebuild_gems`, `r2p2:reset`, `r2p2:setup`, `r2p2:upload`, `r2p2:upload_mrb`. The four deleted tasks must NOT appear.

- [ ] **Step 3: Commit**

```bash
git add Rakefile
git commit -m "chore(rakefile): delete legacy USB-serial / Phase-2 ble_verify tasks"
```

---

## Task 11: Delete `pc/stackchan-protocol/` gem

**Files:**
- Delete: `pc/stackchan-protocol/` (entire directory)

By this point, `Deploy::Picomodem` is installed (Task 8-9), the new `pc/stackchan-ble-client/` gem has the face/LED/codec logic (Tasks 2-5), and the Rakefile no longer references `pc/stackchan-protocol/` (Tasks 9-10).

- [ ] **Step 1: Verify nothing else references the old gem**

Run from project root:

```bash
grep -rn "pc/stackchan-protocol\|stackchan-control\|stackchan-ble-verify" \
  Rakefile docs/superpowers/specs/2026-05-17-ble-phase3-control-cli-design.md \
  pc/stackchan-ble-client/ mrbgems/ 2>&1 | grep -v ":0:" | grep -v "Binary file"
```

Expected: any remaining hits are either inside the spec doc (historical reference) or inside the docs/ tree. No live reference under `Rakefile`, `pc/stackchan-ble-client/`, or `mrbgems/`. If a live reference exists, STOP and fix it before deleting.

- [ ] **Step 2: Delete the directory**

```bash
git rm -rf pc/stackchan-protocol/
```

- [ ] **Step 3: Verify the gemless state**

Run:

```bash
ls pc/
```

Expected: only `stackchan-ble-client/` remains under `pc/`.

Run from project root:

```bash
bundle exec rake r2p2:upload SRC=mrbgems/picoruby-stackchan-protocol/examples/app.rb 2>&1 | head -5
```

(This will start the upload handshake — if it actually connects to a device, abort with Ctrl-C; the point is "the Rakefile launches Deploy::Picomodem.upload without LoadError"; if no CoreS3 is attached, expect an `ESPPORT not set` abort, which is fine.)

- [ ] **Step 4: Commit**

```bash
git add -u pc/
git commit -m "chore: delete pc/stackchan-protocol/ gem (superseded by stackchan-ble-client + lib/deploy/picomodem)"
```

---

## Task 12: LED driver — `fill_range` / `fill_left` / `fill_right` + tests

**Files:**
- Modify: `mrbgems/picoruby-stackchan-led/mrblib/stackchan_led.rb`
- Modify: `mrbgems/picoruby-stackchan-led/test/stackchan_led_test.rb`

`LEFT_RANGE = (0..5)` and `RIGHT_RANGE = (6..11)` are the **draft assumption** from spec §5.4.1 — physical wraparound will be verified in Task 18.

- [ ] **Step 1: Write failing tests**

Append to `mrbgems/picoruby-stackchan-led/test/stackchan_led_test.rb` (at the end of the file, before the final closing of any wrapping module if present):

```ruby
class StackchanLedFillRangeTest < Test::Unit::TestCase
  def setup
    @py32 = FakePY32.new
    @led  = StackchanLed.new(@py32)
    @py32.led_ram_calls.clear  # discard init blank
  end

  def test_fill_range_writes_only_specified_pixels
    @led.fill_range(2, 4, 100, 50, 25)
    @led.show
    last = @py32.led_ram_calls.last
    assert_equal [0, 0, 0],     last[0]
    assert_equal [0, 0, 0],     last[1]
    assert_equal [100, 50, 25], last[2]
    assert_equal [100, 50, 25], last[3]
    assert_equal [100, 50, 25], last[4]
    assert_equal [0, 0, 0],     last[5]
  end

  def test_fill_left_covers_indices_0_to_5
    @led.fill_left(10, 20, 30)
    @led.show
    last = @py32.led_ram_calls.last
    (0..5).each { |i| assert_equal [10, 20, 30], last[i], "pixel #{i}" }
    (6..11).each { |i| assert_equal [0, 0, 0], last[i], "pixel #{i}" }
  end

  def test_fill_right_covers_indices_6_to_11
    @led.fill_right(40, 50, 60)
    @led.show
    last = @py32.led_ram_calls.last
    (0..5).each { |i| assert_equal [0, 0, 0], last[i], "pixel #{i}" }
    (6..11).each { |i| assert_equal [40, 50, 60], last[i], "pixel #{i}" }
  end

  def test_left_and_right_independent
    @led.fill_left(255, 0, 0)
    @led.fill_right(0, 0, 255)
    @led.show
    last = @py32.led_ram_calls.last
    (0..5).each { |i| assert_equal [255, 0, 0], last[i] }
    (6..11).each { |i| assert_equal [0, 0, 255], last[i] }
  end

  def test_constants_LEFT_RANGE_and_RIGHT_RANGE
    assert_equal 0, StackchanLed::LEFT_RANGE.first
    assert_equal 5, StackchanLed::LEFT_RANGE.last
    assert_equal 6, StackchanLed::RIGHT_RANGE.first
    assert_equal 11, StackchanLed::RIGHT_RANGE.last
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd mrbgems/picoruby-stackchan-led && bundle exec rake test 2>&1 | tail -20`
Expected: 5 failures (`NoMethodError` on `fill_range` / `fill_left` / `fill_right` / `NameError` on `LEFT_RANGE`).

- [ ] **Step 3: Implement fill_range / fill_left / fill_right**

Edit `mrbgems/picoruby-stackchan-led/mrblib/stackchan_led.rb`. Add the constants right after `LED_DATA_PIN = 13`:

```ruby
  # Left/right physical pixel index split (draft assumption — verify visually
  # via rake r2p2:ble_control_smoke SIDE=left / SIDE=right and adjust if the
  # physical wraparound differs).
  LEFT_RANGE  = (0..5)
  RIGHT_RANGE = (6..11)
```

Then add these three methods (anywhere in the class body, e.g. after `set_rgb`):

```ruby
  def fill_range(start_idx, end_idx, r, g, b)
    i = start_idx
    while i <= end_idx
      @buffer[i] = [r, g, b]
      i += 1
    end
    self
  end

  def fill_left(r, g, b)
    fill_range(LEFT_RANGE.first, LEFT_RANGE.last, r, g, b)
  end

  def fill_right(r, g, b)
    fill_range(RIGHT_RANGE.first, RIGHT_RANGE.last, r, g, b)
  end
```

(Note: explicit `while` loop instead of `Range#each` because PicoRuby's Range support is partial — `each` works in CRuby tests but ranges on PicoRuby are limited; safest pattern is explicit indexed loop.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd mrbgems/picoruby-stackchan-led && bundle exec rake test 2>&1 | tail -20`
Expected: existing tests pass + 5 new fill_range tests pass.

- [ ] **Step 5: Commit**

```bash
git add mrbgems/picoruby-stackchan-led/mrblib/stackchan_led.rb mrbgems/picoruby-stackchan-led/test/stackchan_led_test.rb
git commit -m "feat(led): add fill_range / fill_left / fill_right + LEFT/RIGHT_RANGE constants"
```

---

## Task 13: LED driver — side-aware Animator + `animate_side` (remove legacy `animate`)

**Files:**
- Modify: `mrbgems/picoruby-stackchan-led/mrblib/stackchan_led/animator.rb`
- Modify: `mrbgems/picoruby-stackchan-led/mrblib/stackchan_led.rb`
- Modify: `mrbgems/picoruby-stackchan-led/test/stackchan_led_test.rb`

`Animator` is parameterized by `pixel_range:` so it writes only to its half. `StackchanLed` owns two animators (left + right). `animate_side(side, r, g, b, mode)` dispatches to the matching animator(s). The legacy `animate(r, g, b, mode)` method is deleted.

- [ ] **Step 1: Write failing tests**

Append to `mrbgems/picoruby-stackchan-led/test/stackchan_led_test.rb`:

```ruby
class StackchanLedAnimateSideTest < Test::Unit::TestCase
  def setup
    @py32 = FakePY32.new
    @led  = StackchanLed.new(@py32)
    @py32.led_ram_calls.clear
  end

  def test_animate_side_both_solid_fills_all_pixels
    @led.animate_side(:both, 100, 50, 25, :solid)
    last = @py32.led_ram_calls.last
    (0..11).each { |i| assert_equal [100, 50, 25], last[i], "pixel #{i}" }
  end

  def test_animate_side_left_solid_fills_only_left_half
    @led.animate_side(:left, 100, 50, 25, :solid)
    last = @py32.led_ram_calls.last
    (0..5).each  { |i| assert_equal [100, 50, 25], last[i], "pixel #{i}" }
    (6..11).each { |i| assert_equal [0, 0, 0], last[i], "pixel #{i}" }
  end

  def test_animate_side_right_solid_fills_only_right_half
    @led.animate_side(:right, 0, 0, 255, :solid)
    last = @py32.led_ram_calls.last
    (0..5).each  { |i| assert_equal [0, 0, 0], last[i], "pixel #{i}" }
    (6..11).each { |i| assert_equal [0, 0, 255], last[i], "pixel #{i}" }
  end

  def test_animate_side_off_clears_only_that_side
    @led.animate_side(:both, 255, 255, 255, :solid)
    @led.animate_side(:left, 0, 0, 0, :off)
    last = @py32.led_ram_calls.last
    (0..5).each  { |i| assert_equal [0, 0, 0], last[i], "pixel #{i}" }
    (6..11).each { |i| assert_equal [255, 255, 255], last[i], "pixel #{i}" }
  end

  def test_animate_side_unknown_raises
    assert_raise(ArgumentError) do
      @led.animate_side(:up, 0, 0, 0, :solid)
    end
  end

  def test_tick_ticks_both_animators
    # Set both sides to blink; advance time; check the buffer flipped.
    @led.animate_side(:both, 255, 0, 0, :blink)
    initial = @py32.led_ram_calls.last.dup
    @led.tick(0)        # at start of phase, blink on
    @led.tick(600)      # after 500ms half-period, blink off
    later = @py32.led_ram_calls.last
    refute_equal initial, later, "tick should have produced a different buffer after 600ms"
  end
end

class StackchanLedLegacyAnimateRemovedTest < Test::Unit::TestCase
  def test_animate_method_no_longer_exists
    led = StackchanLed.new(FakePY32.new)
    refute_respond_to led, :animate
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd mrbgems/picoruby-stackchan-led && bundle exec rake test 2>&1 | tail -20`
Expected: new animate_side tests fail + `test_animate_method_no_longer_exists` fails (method still exists). Also note: existing tests that call `led.animate(...)` directly will start failing once we delete `animate`. They will be updated in Step 4.

- [ ] **Step 3: Refactor Animator to be side-aware**

Replace `mrbgems/picoruby-stackchan-led/mrblib/stackchan_led/animator.rb` entirely with:

```ruby
class StackchanLed
  class Animator
    BLINK_HALF_PERIOD_MS = 500
    BREATHING_LUT = [0, 5, 20, 45, 70, 90, 100, 90, 70, 45, 20, 5].freeze
    BREATHING_STEP_MS = 250

    def initialize(led, pixel_range:)
      @led = led
      @pixel_range = pixel_range
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
      elapsed = now_ms - @phase_start_ms
      case @mode
      when :blink
        on = (elapsed / BLINK_HALF_PERIOD_MS) % 2 == 0
        apply_color(on ? @r : 0, on ? @g : 0, on ? @b : 0)
      when :breathing
        ratio = BREATHING_LUT[(elapsed / BREATHING_STEP_MS) % BREATHING_LUT.size]
        apply_color(@r * ratio / 100, @g * ratio / 100, @b * ratio / 100)
      end
    end

    private

    def dynamic?
      @mode == :blink || @mode == :breathing
    end

    def apply_immediately
      case @mode
      when :solid then apply_color(@r, @g, @b)
      when :off   then apply_color(0, 0, 0)
      end
    end

    def apply_color(r, g, b)
      @led.fill_range(@pixel_range.first, @pixel_range.last, r, g, b)
      @led.show
    end
  end
end
```

- [ ] **Step 4: Update StackchanLed to use side-aware animators and remove legacy `animate`**

Edit `mrbgems/picoruby-stackchan-led/mrblib/stackchan_led.rb`. Remove the existing `def animate(r, g, b, mode) ... end` method block, and replace the existing `tick`/`animator` block with:

```ruby
  def animate_side(side, r, g, b, mode)
    case side
    when :both
      left_animator.set(r, g, b, mode)
      right_animator.set(r, g, b, mode)
    when :left
      left_animator.set(r, g, b, mode)
    when :right
      right_animator.set(r, g, b, mode)
    else
      raise ArgumentError, "unknown side: #{side.inspect}"
    end
    self
  end

  def tick(now_ms)
    left_animator.tick(now_ms)
    right_animator.tick(now_ms)
  end

  private

  def left_animator
    @left_animator ||= Animator.new(self, pixel_range: LEFT_RANGE)
  end

  def right_animator
    @right_animator ||= Animator.new(self, pixel_range: RIGHT_RANGE)
  end
```

(Remove the old `def animator; @animator ||= Animator.new(self); end` line.)

- [ ] **Step 5: Update existing tests that called the old `animate`**

Open `mrbgems/picoruby-stackchan-led/test/stackchan_led_test.rb` and search for `animate(`. For each call to `led.animate(r, g, b, mode)`, replace with `led.animate_side(:both, r, g, b, mode)`. (Same for tests that checked `Animator.new(led)` — replace with `Animator.new(led, pixel_range: StackchanLed::LEFT_RANGE)`.)

- [ ] **Step 6: Run tests to verify they pass**

Run: `cd mrbgems/picoruby-stackchan-led && bundle exec rake test 2>&1 | tail -20`
Expected: all tests pass including the 7 new ones from Step 1.

- [ ] **Step 7: Commit**

```bash
git add mrbgems/picoruby-stackchan-led/
git commit -m "feat(led): side-aware Animator + animate_side (delete legacy animate)"
```

---

## Task 14: Dispatcher S key + FakeLed update

**Files:**
- Modify: `mrbgems/picoruby-stackchan-protocol/mrblib/stackchan_protocol/dispatcher.rb`
- Modify: `mrbgems/picoruby-stackchan-protocol/test/dispatcher_test.rb`
- Modify: `mrbgems/picoruby-stackchan-protocol/test/fake_led.rb`

- [ ] **Step 1: Update FakeLed to track animate_side**

Replace `mrbgems/picoruby-stackchan-protocol/test/fake_led.rb` with:

```ruby
class FakeLed
  attr_reader :animate_side_calls, :tick_calls

  def initialize
    @animate_side_calls = []
    @tick_calls = []
  end

  def animate_side(side, r, g, b, mode)
    @animate_side_calls << [side, r, g, b, mode]
    self
  end

  def tick(now_ms)
    @tick_calls << now_ms
  end

  def last_animate_side_args
    @animate_side_calls.last
  end
end
```

- [ ] **Step 2: Write failing dispatcher tests for S key**

Append to `mrbgems/picoruby-stackchan-protocol/test/dispatcher_test.rb` (after the existing `DispatcherCombinedTest` class):

```ruby
class DispatcherSideKeyTest < Test::Unit::TestCase
  def setup
    @display = FakeDisplay.new
    @led     = FakeLed.new
    @stdout  = FakeStdout.new
    @disp    = StackchanProtocol::Dispatcher.new(
      display: @display, led: @led, stdout: @stdout
    )
  end

  def test_S_both_passes_side_to_animate_side
    @disp.handle({ "L" => "1", "R" => "100", "G" => "0", "B" => "0", "S" => "B", "M" => "s" })
    assert_equal [:both, 100, 0, 0, :solid], @led.last_animate_side_args
    assert_equal ["."], @stdout.writes
  end

  def test_S_left
    @disp.handle({ "L" => "1", "R" => "100", "G" => "0", "B" => "0", "S" => "L", "M" => "s" })
    assert_equal [:left, 100, 0, 0, :solid], @led.last_animate_side_args
  end

  def test_S_right
    @disp.handle({ "L" => "1", "R" => "0", "G" => "0", "B" => "200", "S" => "R", "M" => "b" })
    assert_equal [:right, 0, 0, 200, :blink], @led.last_animate_side_args
  end

  def test_missing_S_writes_error
    @disp.handle({ "L" => "1", "R" => "0", "G" => "0", "B" => "0", "M" => "s" })
    assert_equal ["?"], @stdout.writes
    assert_nil @led.last_animate_side_args
  end

  def test_unknown_S_value_writes_error
    @disp.handle({ "L" => "1", "R" => "0", "G" => "0", "B" => "0", "S" => "X", "M" => "s" })
    assert_equal ["?"], @stdout.writes
    assert_nil @led.last_animate_side_args
  end
end
```

Also fix all existing dispatcher tests that called `led.last_animate_args` — search/replace them:

```bash
cd mrbgems/picoruby-stackchan-protocol/test
sed -i.bak 's/last_animate_args/last_animate_side_args/g' dispatcher_test.rb
```

The existing `DispatcherLedTest` tests pass a frame without an `S` key and check `last_animate_args == [r, g, b, mode]`. With the new strict S-required semantics, those tests will get `?` ACK and `nil` from `last_animate_side_args`. Update each one to include `"S" => "B"` and to expect `[:both, r, g, b, mode]`:

Open `dispatcher_test.rb` and edit each `test_L_*` test inside `DispatcherLedTest`:

* In every `@disp.handle({...})` call inside `DispatcherLedTest`, add `"S" => "B"` to the hash.
* In every `assert_equal [...]` that checks `last_animate_side_args`, prepend `:both` to the expected array.

For `test_L_unknown_mode_writes_error`, the frame already has all fields except S — update to add `"S" => "B"` so the only thing wrong is the mode.

For `DispatcherCombinedTest#test_F_and_L_both_dispatched` and `test_combined_success_writes_single_ack`, add `"S" => "B"` to the frame and expect `[:both, ...]` from animate_side_args.

For `test_combined_partial_failure_writes_error` (which sends `"F" => "9"` + LED off), add `"S" => "B"` to the frame.

- [ ] **Step 3: Run tests to verify they fail (new tests fail before impl change)**

Run: `cd mrbgems/picoruby-stackchan-protocol && bundle exec rake test 2>&1 | tail -20`
Expected: the new `DispatcherSideKeyTest` tests fail because `handle_led` ignores `S` and still calls `animate` (now non-existent or unaware of side). Test infrastructure error if `animate` was already removed in Task 13's mrbgems file scope — that's fine, the next step fixes both.

- [ ] **Step 4: Update Dispatcher#handle_led to require S and call animate_side**

Edit `mrbgems/picoruby-stackchan-protocol/mrblib/stackchan_protocol/dispatcher.rb`. Add `SIDE_TABLE` constant near the existing `MODE_TABLE` (around line 13):

```ruby
    SIDE_TABLE = {
      "L" => :left,
      "R" => :right,
      "B" => :both,
    }.freeze
```

Replace `handle_led` (currently at line 46-54) with:

```ruby
    def handle_led(frame)
      mode = MODE_TABLE[frame["M"]]
      return false unless mode
      side = SIDE_TABLE[frame["S"]]
      return false unless side
      r = (frame["R"] || "0").to_i
      g = (frame["G"] || "0").to_i
      b = (frame["B"] || "0").to_i
      @led.animate_side(side, r, g, b, mode)
      true
    end
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd mrbgems/picoruby-stackchan-protocol && bundle exec rake test 2>&1 | tail -20`
Expected: all dispatcher tests pass including the 5 new S-key tests.

- [ ] **Step 6: Commit**

```bash
git add mrbgems/picoruby-stackchan-protocol/
rm -f mrbgems/picoruby-stackchan-protocol/test/*.bak
git commit -m "feat(dispatcher): require S key for LED frames, dispatch to animate_side"
```

---

## Task 15: `examples/application.rb` (device dispatcher) + delete `ble_smoke.rb`

**Files:**
- Create: `mrbgems/picoruby-stackchan-protocol/examples/application.rb`
- Delete: `mrbgems/picoruby-stackchan-protocol/examples/ble_smoke.rb`

`application.rb` is the production device dispatcher. Structure: `sleep_ms 5000` escape hatch → cold-boot init (copied verbatim from `app.rb`) → BLE NUS service (copied from `ble_smoke.rb`'s `StackChanSmoke`, extended with FrameParser + Dispatcher + AckSink wiring) → `peri.start(0)` for infinite advertise.

- [ ] **Step 1: Create application.rb**

`mrbgems/picoruby-stackchan-protocol/examples/application.rb`:

```ruby
# examples/application.rb — Phase 3 production dispatcher.
#
# Flow:
#   [1] 5s escape hatch (sleep_ms 5000) — crash-loop recovery window
#   [2] cold-boot init (AXP2101 → AW9523 → ILI9342 → PY32 → LED → Face::Neutral)
#   [3] BLE NUS service + Dispatcher + FrameParser + AckSink
#   [4] peri.start(0) — infinite advertise loop
#
# Upload: rake r2p2:upload_mrb SRC=mrbgems/picoruby-stackchan-protocol/examples/application.rb
# Smoke:  rake r2p2:ble_control_smoke COLOR=red MODE=blink FACE=joy SIDE=both

require 'spi'
require 'gpio'
require 'i2c'
require 'machine'
require 'ili9342'
require 'py32-io-expander'
require 'stackchan-led'
require 'stackchan-protocol'
require 'ble'

# [1] 5-second escape hatch. If a previous app.mrb crash-loops the device,
# this window lets a human reach the R2P2 shell and `rm /home/app.mrb` to
# recover. Phase 2 used 2s which was borderline — Phase 3 raises it to 5s.
sleep_ms 5000

# [2] cold-boot init — pinch-perfect copy of app.rb's init block (Phase 2
# bring-up smoke v13-aw9523-p0). Order is critical; see CLAUDE.md
# "CoreS3 cold-boot 初期化シーケンス" section for the why behind each I2C write.
I2C_SDA_PIN  = 12
I2C_SCL_PIN  = 11
AXP2101_ADDR = 0x34
AW9523_ADDR  = 0x58
PY32_ADDR    = 0x6F

puts ""
puts "[application] boot"

i2c = I2C.new(unit: :ESP32_I2C0, frequency: 100_000,
              sda_pin: I2C_SDA_PIN, scl_pin: I2C_SCL_PIN)

i2c.write(AXP2101_ADDR, 0x97, 0x1C)
i2c.write(AXP2101_ADDR, 0x69, 0x35)
i2c.write(AXP2101_ADDR, 0x30, 0x3F)
i2c.write(AXP2101_ADDR, 0x90, 0xBF)
i2c.write(AXP2101_ADDR, 0x94, 28)
i2c.write(AXP2101_ADDR, 0x95, 28)
i2c.write(AXP2101_ADDR, 0x27, 0x00)
i2c.write(AXP2101_ADDR, 0x99, 24)

i2c.write(AW9523_ADDR, 0x02, 0b00000111)
i2c.write(AW9523_ADDR, 0x03, 0b10000001)
i2c.write(AW9523_ADDR, 0x04, 0b00011000)
i2c.write(AW9523_ADDR, 0x05, 0b00001100)
i2c.write(AW9523_ADDR, 0x11, 0b00010000)
i2c.write(AW9523_ADDR, 0x12, 0b11111111)
i2c.write(AW9523_ADDR, 0x13, 0b11111111)
Machine.delay_ms(20)
i2c.write(AW9523_ADDR, 0x03, 0b10000011)
Machine.delay_ms(10)

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

Machine.delay_ms(800)
ver_bytes = i2c.read(PY32_ADDR, 1, 0x02, timeout: 200)
if ver_bytes && ver_bytes.length > 0
  puts sprintf("[application] PY32 REG_VERSION = 0x%02X", ver_bytes.bytes[0])
end

py32 = PY32IOExpander.new(i2c)
py32.set_direction(0, true)
py32.set_pull_mode(0, true)
py32.digital_write(0, true)
Machine.delay_ms(200)

led_init_attempt = 0
led = nil
begin
  led = StackchanLed.new(py32)
rescue IOError
  led_init_attempt += 1
  if led_init_attempt < 6
    Machine.delay_ms(200)
    retry
  end
  raise
end

Machine.delay_ms(50)
led.show
led.brightness = 100
StackchanProtocol::Face::Neutral.new.draw(display)
puts "[application] LCD + LED cold-boot done"

# [3] BLE NUS service. UUID / property masks copied from Phase 2 ble_smoke.rb
# (deleted in this Phase 3 PR; structure lives in application.rb now).
class StackChanApp < BLE
  AD_TYPE_FLAGS = 0x01
  AD_TYPE_COMPLETE_LOCAL_NAME = 0x09
  AD_FLAGS = 0x06
  BTSTACK_EVENT_STATE = 0x60
  HCI_EVENT_DISCONNECTION_COMPLETE = 0x05
  ATT_EVENT_CAN_SEND_NOW = 0xB7

  NUS_SERVICE_UUID = "\x9e\xca\xdc\x24\x0e\xe5\xa9\xe0\x93\xf3\xa3\xb5\x01\x00\x40\x6e"
  NUS_RX_CHAR_UUID = "\x9e\xca\xdc\x24\x0e\xe5\xa9\xe0\x93\xf3\xa3\xb5\x02\x00\x40\x6e"
  NUS_TX_CHAR_UUID = "\x9e\xca\xdc\x24\x0e\xe5\xa9\xe0\x93\xf3\xa3\xb5\x03\x00\x40\x6e"

  NUS_RX_PROPS = BLE::WRITE | BLE::WRITE_WITHOUT_RESPONSE | BLE::DYNAMIC
  NUS_TX_PROPS = BLE::READ | BLE::NOTIFY | BLE::DYNAMIC
  NUS_TX_VAL_PROPS = BLE::READ | BLE::DYNAMIC
  NUS_CCCD_PROPS = BLE::READ | BLE::WRITE | BLE::WRITE_WITHOUT_RESPONSE | BLE::DYNAMIC

  def initialize(display:, led:)
    @display = display
    @led     = led
    @adv_data = build_adv_data
    db = build_gatt_database
    @db = db
    @rx_handle = nus_handle(db, NUS_RX_CHAR_UUID, :value_handle)
    @tx_handle = nus_handle(db, NUS_TX_CHAR_UUID, :value_handle)
    @tx_cccd_handle = nus_handle(db, NUS_TX_CHAR_UUID, BLE::CLIENT_CHARACTERISTIC_CONFIGURATION)
    @notify_enabled = false
    @parser = StackchanProtocol::FrameParser.new
    @ack_queue = ""
    @dispatcher = StackchanProtocol::Dispatcher.new(
      display: @display, led: @led, stdout: self
    )
    super(:peripheral, db.profile_data)
  end

  # AckSink contract: Dispatcher calls `write(byte)` to deliver an ACK byte.
  def write(byte)
    @ack_queue += byte
  end

  def build_adv_data
    BLE::AdvertisingData.build do |a|
      a.add(AD_TYPE_FLAGS, AD_FLAGS)
      a.add(AD_TYPE_COMPLETE_LOCAL_NAME, "StackChan-PicoRuby")
    end
  end

  def build_gatt_database
    BLE::GattDatabase.new do |db|
      db.add_service(BLE::GATT_PRIMARY_SERVICE_UUID, BLE::GAP_SERVICE_UUID) do |s|
        s.add_characteristic(BLE::READ, BLE::GAP_DEVICE_NAME_UUID, BLE::READ, "StackChan-PicoRuby")
      end
      db.add_service(BLE::GATT_PRIMARY_SERVICE_UUID, NUS_SERVICE_UUID) do |s|
        s.add_characteristic(NUS_RX_PROPS, NUS_RX_CHAR_UUID, NUS_RX_PROPS, "")
        s.add_characteristic(NUS_TX_PROPS, NUS_TX_CHAR_UUID, NUS_TX_VAL_PROPS, "") do |c|
          c.add_descriptor(NUS_CCCD_PROPS, BLE::CLIENT_CHARACTERISTIC_CONFIGURATION, "\x00\x00")
        end
      end
    end
  end

  def nus_handle(db, char_uuid, key)
    db.handle_table[NUS_SERVICE_UUID][char_uuid][key]
  end

  def packet_callback(event_packet)
    case event_packet[0]&.ord
    when BTSTACK_EVENT_STATE
      return unless event_packet[2]&.ord == BLE::HCI_STATE_WORKING
      puts "[application] HCI WORKING — advertising"
      advertise(@adv_data)
    when HCI_EVENT_DISCONNECTION_COMPLETE
      puts "[application] disconnected"
      @notify_enabled = false
    when ATT_EVENT_CAN_SEND_NOW
      flush_one_ack
    end
  end

  def heartbeat_callback
    # NUS RX drain
    rx_data = pop_write_value(@rx_handle)
    while rx_data
      @parser.feed(rx_data).each do |frame|
        @dispatcher.handle(frame)
      end
      rx_data = pop_write_value(@rx_handle)
    end
    # CCCD subscribe state
    cccd = pop_write_value(@tx_cccd_handle)
    if cccd
      @notify_enabled = (cccd == "\x01\x00")
      puts "[application] notify #{@notify_enabled ? 'enabled' : 'disabled'}"
    end
    # Tick LED animator
    @led.tick(Machine.uptime_us / 1000)
    # Request can_send_now if we have ACK bytes queued and the central is subscribed
    if @notify_enabled && @ack_queue.bytesize > 0
      request_can_send_now_event
    end
  end

  def flush_one_ack
    return if @ack_queue.bytesize == 0
    byte = @ack_queue[0, 1]
    @ack_queue = @ack_queue[1, @ack_queue.bytesize - 1] || ""
    push_read_value(@tx_handle, byte)
    notify(@tx_handle)
  end
end

# [4] Infinite advertise. peri.start(0) puts BTstack's run_loop in steady
# state — if `0` does not mean infinite on this picoruby-ble fork, swap to
# a very large millisecond value (e.g. 0xFFFFFFFF) and document in
# CLAUDE.md.
puts "[application] BLE peripheral starting (infinite advertise)"
peri = StackChanApp.new(display: display, led: led)
peri.debug = true
peri.start(0)
puts "[application] start returned — should not reach here under normal operation"
```

- [ ] **Step 2: Delete ble_smoke.rb**

```bash
git rm mrbgems/picoruby-stackchan-protocol/examples/ble_smoke.rb
```

- [ ] **Step 3: Syntax-check application.rb with host picorbc**

If the R2P2-ESP32 host picoruby is built (i.e. `rake r2p2:setup` already ran), verify the file compiles:

```bash
PICORBC=$(realpath ../../bash0C7/R2P2-ESP32/components/picoruby-esp32/picoruby/bin/picorbc) && \
  $PICORBC -o /tmp/application.mrb mrbgems/picoruby-stackchan-protocol/examples/application.rb && \
  ls -la /tmp/application.mrb
```

Expected: `.mrb` file is created with non-zero size. If picorbc is not built, skip this step and rely on Task 18's `rake r2p2:upload_mrb`, which will run picorbc as part of its body.

- [ ] **Step 4: Commit**

```bash
git add mrbgems/picoruby-stackchan-protocol/examples/application.rb
git commit -m "feat(device): add examples/application.rb (Phase 3 production dispatcher); delete ble_smoke.rb"
```

---

## Task 16: Rakefile — add `r2p2:ble_control_smoke`

**Files:**
- Modify: `Rakefile`

- [ ] **Step 1: Add the smoke task**

Inside `namespace :r2p2 do`, append (after `r2p2:upload_mrb`):

```ruby
  # E2E smoke: upload application.mrb → reset → wait autostart → send a
  # control frame via stackchan-ble-control combo. Exits with the CLI's
  # exit code so the rake invocation surfaces structured failure (0/2/3/4/5).
  desc 'BLE control E2E smoke (COLOR=red MODE=blink FACE=joy SIDE=both AUTOSTART_WAIT=12)'
  task :ble_control_smoke do
    color = ENV.fetch('COLOR', 'red')
    mode  = ENV.fetch('MODE',  'solid')
    face  = ENV.fetch('FACE',  'neutral')
    side  = ENV.fetch('SIDE',  'both')
    autostart_wait = ENV.fetch('AUTOSTART_WAIT', '12').to_i

    ENV['SRC'] = 'mrbgems/picoruby-stackchan-protocol/examples/application.rb'
    Rake::Task['r2p2:upload_mrb'].invoke
    Rake::Task['r2p2:reset'].invoke

    puts "[smoke] waiting #{autostart_wait}s for autostart (5s escape + BLE init + advertise)"
    sleep autostart_wait

    Dir.chdir(File.expand_path('pc/stackchan-ble-client', __dir__)) do
      ok = system('bundle', 'exec', 'exe/stackchan-ble-control',
                  '--side', side,
                  'combo',
                  '--face', face,
                  '--led',  "#{color} #{mode}")
      unless ok
        # Propagate the CLI's exit code so the rake call surfaces structured failure.
        exit $?.exitstatus
      end
    end

    puts "[smoke] PASS — face=#{face} LED=#{color} #{mode} (side=#{side}) — visual check please"
  end
```

- [ ] **Step 2: Verify Rakefile parses**

Run:

```bash
bundle exec rake -T r2p2:ble_control_smoke
```

Expected: the smoke task appears in the list with the description.

- [ ] **Step 3: Commit**

```bash
git add Rakefile
git commit -m "feat(rakefile): add r2p2:ble_control_smoke E2E task"
```

---

## Task 17: Rebuild R2P2 firmware with the updated mrbgems

After Tasks 12-15 the device-side mrblib code changed (`stackchan_led.rb`, `stackchan_led/animator.rb`, `dispatcher.rb`). Per CLAUDE.md "既存 gem の mrblib/*.rb 内容を変えただけなら軽量修復ルート" the cheap path is `rake r2p2:rebuild_gems` + `rake r2p2:build_flash`, not a full `r2p2:setup`.

- [ ] **Step 1: Force mrbgem bytecode rebuild and reflash**

Run (from project root, via subagent since this is a long-running rake task):

```bash
bundle exec rake r2p2:rebuild_gems r2p2:build_flash
```

Expected: `idf.py build flash` completes, CoreS3 reflashed. Build time ~5-10 minutes; per CLAUDE.md this rake must run in a foreground subagent (haiku, large timeout 600000ms+).

If `rebuild_gems` complains that `libmruby.a` is already absent, that's fine — the build will run the picoruby rake regardless.

- [ ] **Step 2: Verify the device boots and reaches shell**

After build+flash completes, give the device 8-12 seconds to boot. Capture a brief serial trace:

```bash
mkdir -p tmp/longrun
cat /dev/cu.usbmodem* > tmp/longrun/boot.log &
CAT_PID=$!
bundle exec rake r2p2:reset
sleep 12
kill $CAT_PID 2>/dev/null
head -40 tmp/longrun/boot.log
```

Expected: at minimum, the R2P2 banner / shell prompt should appear. If `/home/app.mrb` is left over from a previous flash, the device may auto-start it; that's fine but the boot log should still show evidence of bring-up.

- [ ] **Step 3: Commit (none needed — this task only changes flash, no repo edits)**

Skip the commit step. Proceed to Task 18.

---

## Task 18: E2E smoke verification + left/right index fine-tune

**Files:** none modified by default; `mrbgems/picoruby-stackchan-led/mrblib/stackchan_led.rb` only if Step 3 finds the LEFT/RIGHT ranges are wrong.

- [ ] **Step 1: Upload application.mrb and confirm autostart**

```bash
bundle exec rake r2p2:upload_mrb SRC=mrbgems/picoruby-stackchan-protocol/examples/application.rb
bundle exec rake r2p2:reset
sleep 12
```

(Manual capture: confirm that the LCD draws the neutral face after reset.)

- [ ] **Step 2: Run the smoke for SIDE=both**

```bash
bundle exec rake r2p2:ble_control_smoke COLOR=red MODE=blink FACE=joy SIDE=both
echo "exit=$?"
```

Expected: `[smoke] PASS — face=joy LED=red blink (side=both) — visual check please`, `exit=0`. Visually: all 12 LEDs blink red; face changes to joy.

If exit code is non-zero, consult `[FAIL]` line on stderr and follow the structured exit code mapping (2/3/4/5/9 from spec §4.5) to debug.

- [ ] **Step 3: Run with SIDE=left and SIDE=right and verify the physical halves**

```bash
bundle exec rake r2p2:ble_control_smoke COLOR=blue MODE=solid FACE=joy SIDE=left
sleep 1
bundle exec rake r2p2:ble_control_smoke COLOR=green MODE=solid FACE=joy SIDE=right
```

Visually inspect: after the two commands, the ring should show **one half blue, the other half green**, with the split aligned to the device's natural left/right (as the user faces the device).

If the split is rotated (e.g. blue appears on top/bottom rather than left/right, or left/right are swapped), edit `mrbgems/picoruby-stackchan-led/mrblib/stackchan_led.rb` to adjust `LEFT_RANGE` / `RIGHT_RANGE`. The 12 LEDs are arranged around a ring; possible fine-tunes:

* Swap: `LEFT_RANGE = (6..11)` / `RIGHT_RANGE = (0..5)` if mirrored
* Rotate: `LEFT_RANGE = (9..11).to_a + (0..2).to_a` (custom array — would also need to change `fill_range` to accept an enumerable instead of start/end). If a non-contiguous range is needed, restructure to a `LEFT_INDICES = [9, 10, 11, 0, 1, 2]` array and iterate explicitly.

Re-run Step 2 (build_flash) and re-verify until the split is correct.

- [ ] **Step 4: Run with mode=blink, mode=breathing, and verify the animation runs**

```bash
bundle exec rake r2p2:ble_control_smoke COLOR=red MODE=blink FACE=neutral SIDE=both
# observe 5-10 seconds of blink
bundle exec rake r2p2:ble_control_smoke COLOR=green MODE=breathing FACE=neutral SIDE=both
# observe 5-10 seconds of breathing
bundle exec rake r2p2:ble_control_smoke COLOR=off MODE=off FACE=neutral SIDE=both
# all LEDs off
```

Expected: blink is roughly 1Hz on/off; breathing is a smooth 3-second cycle.

- [ ] **Step 5: Run with all 4 face names**

```bash
for f in neutral smile joy surprised; do
  bundle exec rake r2p2:ble_control_smoke COLOR=off MODE=off FACE=$f SIDE=both
  sleep 1
done
```

Expected: LCD redraws to each face. (Each redraw clears the screen to black then draws the mouth/eyes for that face per `StackchanProtocol::Face::*`.)

- [ ] **Step 6: Commit any LEFT/RIGHT_RANGE fine-tunes (if Step 3 required edits)**

```bash
git add mrbgems/picoruby-stackchan-led/mrblib/stackchan_led.rb
git commit -m "fix(led): adjust LEFT_RANGE / RIGHT_RANGE after E2E visual verification"
```

Otherwise skip the commit.

---

## Task 19: README for `pc/stackchan-ble-client`

**Files:**
- Create: `pc/stackchan-ble-client/README.md`

- [ ] **Step 1: Write the README**

`pc/stackchan-ble-client/README.md`:

```markdown
# stackchan-ble-client

BLE control SDK for the M5Stack StackChan running PicoRuby firmware (see [stackchan-picoruby](https://github.com/bash0C7/stackchan-picoruby)). Connects via Nordic UART Service and exposes a block-DSL for face / LED frames with left/right side support and four color forms (named symbol, RGB hex, HSB hex, mode keyword).

## Requirements

- Ruby ≥ 3.1
- Mac with Bluetooth (CoreBluetooth)
- [rb-corebluetooth-mac](https://github.com/bash0C7/rb-corebluetooth-mac) (path-loaded — see `Gemfile`)
- The StackChan device running `examples/application.rb` (advertises as `StackChan-PicoRuby`)

## Quick start

```ruby
require "stackchan_ble_client"

client = StackchanBleClient::Client.new(device_name: "StackChan-PicoRuby")
client.connect

client.send do |stackchan|
  stackchan.face(:joy)
  stackchan.led(:red, mode: :blink)
end

client.send do |stackchan|
  stackchan.led(:blue, side: :left)
  stackchan.led(:green, side: :right)
end

client.send do |stackchan|
  stackchan.led(:rgb, 0xFF8000)             # 24-bit RGB packed
  stackchan.led(:hsb, 0x00FFFF, side: :left)  # 24-bit HSB packed (H/S/B each 0-255)
end

client.disconnect
```

### Block DSL aggregation rules

- `face` is a single key; calling `stackchan.face(...)` multiple times within one block uses the last one.
- `led` is keyed by `(side)` — `:left` / `:right` / `:both` are independent; each defaults to the last call for that side.
- Within one `#send` block, up to 4 frames are emitted: `face` + one per side that was touched.
- Frames are emitted in the order each key was first mentioned in the block.
- ACK is 1 byte from the device per frame (`.` = OK, `?` = error → `DeviceError` raised).

## CLI

```bash
bundle exec stackchan-ble-control face joy
bundle exec stackchan-ble-control led red blink --side left
bundle exec stackchan-ble-control led-rgb 0xFF8000 --mode blink
bundle exec stackchan-ble-control led-hsb 0x00FFFF --side right
bundle exec stackchan-ble-control combo --face joy --led 'red blink'
bundle exec stackchan-ble-control raw '<F:0>'
```

Exit codes:

| code | meaning |
|---|---|
| 0 | success |
| 2 | adapter (CoreBluetooth state error) |
| 3 | timeout (scan / connect / ACK) |
| 4 | connection (lost or refused) |
| 5 | assertion (unknown face name, device rejected with `?` ACK) |
| 9 | uncategorized |

## License

MIT
```

- [ ] **Step 2: Commit**

```bash
git add pc/stackchan-ble-client/README.md
git commit -m "docs(ble-client): add README"
```

---

## Self-Review (run after the plan is written)

This section is for the plan author. Don't include it in subagent task execution.

**Spec coverage check** (mapping spec §X → task):

| Spec section | Implemented in task |
|---|---|
| §2 #1 servo Phase 3.5 分離 | (out of scope, no task) ✓ |
| §2 #2 LED 左右分離 | Tasks 12-14 |
| §2 #3 4 color forms | Tasks 2-5 (table + codec + HSB + send_builder) |
| §2 #4 block DSL | Task 5 |
| §2 #5 stackchan-ble-client gem | Tasks 1-7 |
| §2 #6 pc/stackchan-protocol 廃止 | Tasks 8-11 |
| §2 #7 application.rb | Task 15 |
| §2 #8 5s escape hatch + 無限 advertise | Task 15 |
| §2 #9 face/LED 分離送信 | Task 5 (send_builder produces independent frames) |
| §2 #10 WebSocket 後回し | (out of scope) ✓ |
| §4.2 高レベル API | Task 6 |
| §4.3 block DSL semantics | Task 5 |
| §4.4 color forms | Tasks 2, 3, 4, 5 |
| §4.5 stackchan-ble-control exe | Task 7 |
| §5.2 application.rb structure | Task 15 |
| §5.3 Dispatcher S key | Task 14 |
| §5.4 LED driver fill_range / animate_side | Tasks 12-13 |
| §6 frame protocol on BLE | Tasks 3, 14 |
| §7 lib/deploy/picomodem + Rakefile reorg | Tasks 8-11 |
| §8 r2p2:ble_control_smoke | Task 16 |
| §9 host unit tests | Tasks 2-6, 12-14 |
| §11 draft assumption #1 (LED index) | Task 18 step 3 |
| §11 draft assumption #2 (peri.start(0)) | Task 15 + comment in code, verify at runtime |
| §11 draft assumption #3 (AckSink queue strategy) | Task 15 inline (heartbeat + can_send_now) |
| §11 draft assumption #5 (write_without_response back-pressure) | Task 18 — implicit via multi-frame send |

**Placeholder scan:** No "TBD" / "TODO" / "Similar to Task N" / "implement later" found in this plan.

**Type consistency:**
- `face_name:` keyword used consistently in `FrameCodec.encode_face` and `SendBuilder#face`.
- `side:` symbol values `:left`/`:right`/`:both` consistent across `FrameCodec`, `SendBuilder`, `Client#send`, exe CLI, `Dispatcher`, `StackchanLed#animate_side`, `Animator`.
- `mode:` symbol values `:solid`/`:blink`/`:breathing`/`:off` consistent.
- `animate_side(side, r, g, b, mode)` signature matches between `StackchanLed` (Task 13) and `FakeLed` (Task 14) and `Dispatcher#handle_led` call site (Task 14).
- `parse_ack` returns `:ok` / `:error` symbols; consumed in `Client#send_frame`.

No issues found. Plan ready for execution.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-05-17-ble-phase3-control-cli.md`. Two execution options:

**1. Subagent-Driven (recommended)** — dispatch a fresh subagent per task, review between tasks, fast iteration. The plan was written with that in mind: each task is self-contained, lists exact files and steps, and ends with a commit.

**2. Inline Execution** — execute tasks in this session using `superpowers:executing-plans`, batch with checkpoints for review.

**Which approach?**
