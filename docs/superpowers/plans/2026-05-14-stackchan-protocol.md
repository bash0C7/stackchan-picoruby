# stackchan-protocol Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** PC ⇔ StackChan の最小 USB-Serial プロトコル（1 byte 固定長、3 顔切替 + 1 byte エラー応答）を、StackChan 側 mrbgem `picoruby-stackchan-protocol` と PC 側 gem `pc/stackchan-protocol` の両方で実装し、host テスト full pass + 実機検証手順 doc までを揃える。

**Architecture:** spec §4.1 のデータフロー — PC CLI (`stackchan-control`) → `StackchanProtocol::Client` → tenderlove/uart → USB-CDC → CoreS3 R2P2-ESP32 autostart `/home/app.rb` → `StackchanProtocol::Dispatcher#run` (STDIN.read(1) loop) → vocabulary 解釈 → `Face::{Neutral,Smile,Joy}#draw(display)` → `picoruby-ili9342`。Dispatcher は display インスタンスを外から DI、Face は class 階層、エラーは `STDOUT.write('?')` で統合。

**Tech Stack:** PicoRuby 4.0 系 (mruby VM, R2P2-ESP32) / mrbgem 構造は `bash0C7/picoruby-mpu6886` 踏襲 / CRuby + `test-unit` で host テスト / PC 側は `uart` gem (tenderlove/uart, termios ラッパー) / Bundler 管理 (`bundle install --path vendor/bundle`)

**Branch policy:** 既存 `feature/stackchan-display-bringup` のまま commit を積む（display bring-up は host テスト完了、実機検証だけ pending。本 spec は picoruby-ili9342 に依存するので別ブランチに切ると rebase コストが高い。実機検証は両方 flash 通った後にまとめてやる）。

---

## File structure (new + modified files)

```
stackchan-picoruby/
├── mrbgems/picoruby-stackchan-protocol/         ← 新規
│   ├── README.md
│   ├── Gemfile
│   ├── Gemfile.lock           (bundle install 後に生成)
│   ├── Rakefile
│   ├── LICENSE
│   ├── mrbgem.rake
│   ├── mrblib/
│   │   └── stackchan_protocol.rb
│   ├── sig/
│   │   └── stackchan_protocol.rbs
│   ├── examples/
│   │   └── app.rb
│   └── test/
│       ├── test_helper.rb
│       ├── fake_display.rb
│       ├── fake_stdio.rb
│       └── stackchan_protocol_test.rb
├── pc/stackchan-protocol/                       ← 新規
│   ├── README.md
│   ├── Gemfile
│   ├── Gemfile.lock           (bundle install 後に生成)
│   ├── stackchan-protocol.gemspec
│   ├── Rakefile
│   ├── lib/
│   │   ├── stackchan_protocol.rb
│   │   └── stackchan_protocol/
│   │       ├── version.rb
│   │       ├── face_table.rb
│   │       └── client.rb
│   ├── exe/
│   │   └── stackchan-control
│   └── test/
│       ├── test_helper.rb
│       ├── fake_uart.rb
│       ├── client_test.rb
│       └── cli_test.rb
├── docs/STACKCHAN_PROTOCOL_VERIFICATION.md      ← 新規
└── README.md                                    ← 修正 (status table)
```

`bash0C7/R2P2-ESP32` 側（別リポジトリ、本 plan で 1 行追加）：
```
components/picoruby-esp32/build_config/xtensa-esp-picoruby.rb   ← 修正
```

**責任分担：**
- `mrblib/stackchan_protocol.rb` — Dispatcher + Face 階層を 1 ファイルにまとめる（picoruby-ili9342 が `mrblib/ili9342.rb` 1 ファイル構造なのに合わせる、mrbgem は file 分割すると require 順や PicoRuby 側 require 解決でハマる経験あり）
- `test/fake_display.rb` — display I/F (fill/draw_ellipse/draw_line) の呼び出し履歴を取る mock
- `test/fake_stdio.rb` — FakeStdin (`read(1)` で先頭 byte 返す) と FakeStdout (`write` 履歴)
- `lib/stackchan_protocol/face_table.rb` — `FACE_BYTES = { neutral: '0', smile: '1', joy: '2' }`
- `lib/stackchan_protocol/client.rb` — UART クラスを DI 可能にし、host テストで FakeUart 注入
- `exe/stackchan-control` — optparse + 引数 dispatch

---

## Phase A: StackChan 側 mrbgem — 基本ファイル & テスト基盤

### Task 1: mrbgem ディレクトリと基本ファイル雛形を作る

**Files:**
- Create: `mrbgems/picoruby-stackchan-protocol/Gemfile`
- Create: `mrbgems/picoruby-stackchan-protocol/Rakefile`
- Create: `mrbgems/picoruby-stackchan-protocol/LICENSE`
- Create: `mrbgems/picoruby-stackchan-protocol/mrbgem.rake`
- Create: `mrbgems/picoruby-stackchan-protocol/README.md`

- [ ] **Step 1: ディレクトリ作る**

Run:
```bash
mkdir -p mrbgems/picoruby-stackchan-protocol/{mrblib,sig,examples,test}
```

- [ ] **Step 2: `Gemfile` を picoruby-ili9342 と同一内容で作成**

`mrbgems/picoruby-stackchan-protocol/Gemfile`:
```ruby
source "https://rubygems.org"

gem "rake", "~> 13.0"
gem "test-unit", "~> 3.6"
```

- [ ] **Step 3: `Rakefile` を picoruby-ili9342 と同一構造で作成**

`mrbgems/picoruby-stackchan-protocol/Rakefile`:
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

- [ ] **Step 4: `LICENSE` を picoruby-ili9342 からコピー**

Run:
```bash
cp mrbgems/picoruby-ili9342/LICENSE mrbgems/picoruby-stackchan-protocol/LICENSE
```

- [ ] **Step 5: `mrbgem.rake` を作成（依存はまだ仮、Task 14 で確定）**

`mrbgems/picoruby-stackchan-protocol/mrbgem.rake`:
```ruby
MRuby::Gem::Specification.new('picoruby-stackchan-protocol') do |spec|
  spec.license = 'MIT'
  spec.author  = 'bash0C7'
  spec.summary = 'StackChan ⇔ PC USB-serial 1-byte protocol dispatcher and procedural face renderer'

  spec.add_dependency 'picoruby-ili9342'
  spec.add_test_dependency 'picoruby-picotest'
end
```

- [ ] **Step 6: `README.md` placeholder を作成（中身は Task 14 で更新）**

`mrbgems/picoruby-stackchan-protocol/README.md`:
```markdown
# picoruby-stackchan-protocol

StackChan ⇔ PC の USB-serial 1-byte プロトコル ディスパッチャと、neutral / smile / joy 3 表情の手続き的顔描画を提供する PicoRuby mrbgem。

詳細は `docs/superpowers/specs/2026-05-14-stackchan-protocol-design.md` を参照。
```

- [ ] **Step 7: `bundle install` で Gemfile.lock 生成**

Run:
```bash
cd mrbgems/picoruby-stackchan-protocol && bundle install --path vendor/bundle
```

Expected: `Bundle complete!` 表示。`Gemfile.lock` が生成される。

- [ ] **Step 8: `vendor/bundle/` を gitignore に追加**

`.gitignore` を確認して `mrbgems/*/vendor/bundle/` が無ければ追加。picoruby-ili9342 でも同じパターンが既にあるので、その既存ルールでカバーされるなら何もしない。

Run:
```bash
git check-ignore mrbgems/picoruby-stackchan-protocol/vendor/bundle/
```

Expected: gitignore でマッチする path が出力される。出力されないなら .gitignore に行追加。

- [ ] **Step 9: rake test で empty pass を確認**

Run:
```bash
cd mrbgems/picoruby-stackchan-protocol && bundle exec rake test
```

Expected: `0 tests, 0 assertions, 0 failures, 0 errors` （test ファイル無いので zero）。失敗なら Rakefile typo / test ディレクトリ存在を確認。

- [ ] **Step 10: 中間 commit**

```bash
git add mrbgems/picoruby-stackchan-protocol/
git commit -m "chore(stackchan-protocol): scaffold mrbgem directory and bundler setup"
```

---

### Task 2: FakeDisplay mock

**Files:**
- Create: `mrbgems/picoruby-stackchan-protocol/test/fake_display.rb`
- Create: `mrbgems/picoruby-stackchan-protocol/test/test_helper.rb`
- Create: `mrbgems/picoruby-stackchan-protocol/test/stackchan_protocol_test.rb`

- [ ] **Step 1: test_helper.rb を作成（picoruby-ili9342 を参考に簡素版）**

`mrbgems/picoruby-stackchan-protocol/test/test_helper.rb`:
```ruby
$LOAD_PATH.unshift File.expand_path("../mrblib", __dir__)
$LOAD_PATH.unshift File.expand_path(".", __dir__)

# PicoRuby shim: ILI9342 is supplied by the picoruby-ili9342 mrbgem at runtime.
# For host tests we don't need the real class — the FakeDisplay records calls.
unless defined?(ILI9342)
  class ILI9342
    module Color
      BLACK = 0x0000
      WHITE = 0xFFFF
    end
  end
end

require "test/unit"
require "fake_display"
require "fake_stdio"
```

- [ ] **Step 2: FakeDisplay を作成**

`mrbgems/picoruby-stackchan-protocol/test/fake_display.rb`:
```ruby
# Records the sequence of draw calls made on a display instance.
# Each entry is [method_symbol, args_array].
class FakeDisplay
  attr_reader :calls

  def initialize
    @calls = []
    @raise_on_fill = nil
  end

  # When set to a truthy exception class/instance, the next #fill call raises it.
  attr_accessor :raise_on_fill

  def fill(color)
    raise @raise_on_fill if @raise_on_fill
    @calls << [:fill, [color]]
    nil
  end

  def draw_ellipse(cx, cy, rx, ry, color, fill: false)
    @calls << [:draw_ellipse, [cx, cy, rx, ry, color, { fill: fill }]]
    nil
  end

  def draw_line(x0, y0, x1, y1, color)
    @calls << [:draw_line, [x0, y0, x1, y1, color]]
    nil
  end

  def reset_log!
    @calls = []
    @raise_on_fill = nil
  end
end
```

- [ ] **Step 3: FakeStdio を作成（先に空ファイルだけ用意し、Task 3 で中身を書く）**

`mrbgems/picoruby-stackchan-protocol/test/fake_stdio.rb`:
```ruby
# Placeholder — filled in Task 3.
```

- [ ] **Step 4: 最小テストファイルを作って harness が動くことを確認**

`mrbgems/picoruby-stackchan-protocol/test/stackchan_protocol_test.rb`:
```ruby
require "test_helper"

class FakeDisplayHarnessTest < Test::Unit::TestCase
  def test_fill_records_call
    d = FakeDisplay.new
    d.fill(0x0000)
    assert_equal [[:fill, [0x0000]]], d.calls
  end

  def test_draw_ellipse_records_keyword_arg
    d = FakeDisplay.new
    d.draw_ellipse(10, 20, 5, 6, 0xFFFF, fill: true)
    assert_equal [[:draw_ellipse, [10, 20, 5, 6, 0xFFFF, { fill: true }]]], d.calls
  end

  def test_draw_line_records_call
    d = FakeDisplay.new
    d.draw_line(0, 0, 10, 10, 0xFFFF)
    assert_equal [[:draw_line, [0, 0, 10, 10, 0xFFFF]]], d.calls
  end

  def test_fill_raises_when_configured
    d = FakeDisplay.new
    d.raise_on_fill = StandardError.new("boom")
    assert_raises(StandardError) { d.fill(0x0000) }
  end
end
```

- [ ] **Step 5: rake test で green を確認**

Run:
```bash
cd mrbgems/picoruby-stackchan-protocol && bundle exec rake test
```

Expected: `4 tests, 4 assertions, 0 failures, 0 errors`

- [ ] **Step 6: 中間 commit**

```bash
git add mrbgems/picoruby-stackchan-protocol/test/
git commit -m "test(stackchan-protocol): add FakeDisplay and harness"
```

---

### Task 3: FakeStdio mock

**Files:**
- Modify: `mrbgems/picoruby-stackchan-protocol/test/fake_stdio.rb`
- Modify: `mrbgems/picoruby-stackchan-protocol/test/stackchan_protocol_test.rb`

- [ ] **Step 1: FakeStdin / FakeStdout を実装**

`mrbgems/picoruby-stackchan-protocol/test/fake_stdio.rb`:
```ruby
# Returns bytes one at a time via #read(1). Returns nil when bytes are exhausted
# — Dispatcher#run uses that as end-of-stream signal so tests don't hang.
class FakeStdin
  def initialize(bytes_string)
    @buffer = bytes_string.dup
  end

  def read(n)
    return nil if @buffer.empty?
    raise ArgumentError, "FakeStdin only supports read(1)" unless n == 1
    @buffer.slice!(0, 1)
  end
end

# Records #write history. Each entry is the string passed (1-byte expected).
class FakeStdout
  attr_reader :writes

  def initialize
    @writes = []
  end

  def write(s)
    @writes << s.to_s
    s.to_s.bytesize
  end

  def reset_log!
    @writes = []
  end
end
```

- [ ] **Step 2: FakeStdio の harness テストを追加**

`mrbgems/picoruby-stackchan-protocol/test/stackchan_protocol_test.rb` の末尾に append：
```ruby
class FakeStdinHarnessTest < Test::Unit::TestCase
  def test_reads_one_byte_at_a_time
    s = FakeStdin.new("abc")
    assert_equal "a", s.read(1)
    assert_equal "b", s.read(1)
    assert_equal "c", s.read(1)
    assert_nil s.read(1)
  end

  def test_rejects_non_one_reads
    s = FakeStdin.new("abc")
    assert_raises(ArgumentError) { s.read(2) }
  end
end

class FakeStdoutHarnessTest < Test::Unit::TestCase
  def test_records_writes
    o = FakeStdout.new
    o.write("?")
    o.write("X")
    assert_equal ["?", "X"], o.writes
  end

  def test_returns_bytesize
    o = FakeStdout.new
    assert_equal 1, o.write("?")
  end
end
```

- [ ] **Step 3: rake test で green**

Run:
```bash
cd mrbgems/picoruby-stackchan-protocol && bundle exec rake test
```

Expected: `8 tests, 9 assertions, 0 failures, 0 errors` (FakeDisplay 4 + FakeStdin 2 + FakeStdout 2)

- [ ] **Step 4: 中間 commit**

```bash
git add mrbgems/picoruby-stackchan-protocol/test/
git commit -m "test(stackchan-protocol): add FakeStdin/FakeStdout mocks"
```

---

## Phase B: StackChan 側 mrbgem — Face 描画ロジック (TDD)

### Task 4: `Face::Base` の eyes 描画 (TDD)

**Files:**
- Create: `mrbgems/picoruby-stackchan-protocol/mrblib/stackchan_protocol.rb`
- Modify: `mrbgems/picoruby-stackchan-protocol/test/stackchan_protocol_test.rb`

Eye 座標は既存 `mrbgems/picoruby-ili9342/examples/_face.rb:23-27` を踏襲（320×240 landscape、画面中央=(160,120) 基準で左目 (90,104) / 右目 (230,104)、両眼とも EYE_RX = EYE_RY = 16、白塗り fill: true）。

- [ ] **Step 1: 失敗テストを書く**

`mrbgems/picoruby-stackchan-protocol/test/stackchan_protocol_test.rb` の末尾に append：
```ruby
require "stackchan_protocol"

class FaceBaseEyesTest < Test::Unit::TestCase
  def setup
    @display = FakeDisplay.new
    @face = StackchanProtocol::Face::Base.new
  end

  def test_draw_eyes_emits_two_filled_ellipses
    @face.draw_eyes(@display)
    ellipse_calls = @display.calls.select { |c| c.first == :draw_ellipse }
    assert_equal 2, ellipse_calls.size, "must draw both eyes"
  end

  def test_left_eye_at_upstream_coords
    @face.draw_eyes(@display)
    left = @display.calls.first
    assert_equal :draw_ellipse, left.first
    cx, cy, rx, ry, color, opts = left.last
    assert_equal 90,  cx
    assert_equal 104, cy
    assert_equal 16,  rx
    assert_equal 16,  ry
    assert_equal ILI9342::Color::WHITE, color
    assert_equal({ fill: true }, opts)
  end

  def test_right_eye_at_mirrored_coords
    @face.draw_eyes(@display)
    right = @display.calls[1]
    cx, cy, * = right.last
    assert_equal 230, cx
    assert_equal 104, cy
  end
end
```

- [ ] **Step 2: rake test で fail を確認**

Run:
```bash
cd mrbgems/picoruby-stackchan-protocol && bundle exec rake test
```

Expected: FAIL — `LoadError: cannot load such file -- stackchan_protocol` または `NameError: uninitialized constant StackchanProtocol`.

- [ ] **Step 3: `mrblib/stackchan_protocol.rb` に最小実装**

```ruby
module StackchanProtocol
  module Face
    EYE_LEFT_CX  = 90
    EYE_LEFT_CY  = 104
    EYE_RIGHT_CX = 230
    EYE_RIGHT_CY = 104
    EYE_RX       = 16
    EYE_RY       = 16

    EYE_COLOR        = ILI9342::Color::WHITE
    MOUTH_COLOR      = ILI9342::Color::WHITE
    BACKGROUND_COLOR = ILI9342::Color::BLACK

    MOUTH_CX         = 160
    MOUTH_CY         = 146
    MOUTH_HALF_WIDTH = 45

    class Base
      def draw_eyes(display)
        display.draw_ellipse(EYE_LEFT_CX,  EYE_LEFT_CY,  EYE_RX, EYE_RY, EYE_COLOR, fill: true)
        display.draw_ellipse(EYE_RIGHT_CX, EYE_RIGHT_CY, EYE_RX, EYE_RY, EYE_COLOR, fill: true)
      end
    end
  end
end
```

- [ ] **Step 4: rake test で green**

Run:
```bash
cd mrbgems/picoruby-stackchan-protocol && bundle exec rake test
```

Expected: `11 tests, 16 assertions, 0 failures, 0 errors` (previous 8 + 3 new).

- [ ] **Step 5: 中間 commit**

```bash
git add mrbgems/picoruby-stackchan-protocol/mrblib/stackchan_protocol.rb mrbgems/picoruby-stackchan-protocol/test/stackchan_protocol_test.rb
git commit -m "feat(stackchan-protocol): Face::Base#draw_eyes"
```

---

### Task 5: `Face::Base#draw_mouth` (TDD)

Mouth は `mrbgems/picoruby-ili9342/examples/_face.rb:52-61` のロジックを踏襲：中点 (160,146) から両端 ±45px 離れた箇所まで、`delta_y` pixel 上げた "inverted-V" を draw_line 2 本で描く。delta_y=0 で水平、>0 で上向きカーブ。

- [ ] **Step 1: 失敗テストを追加**

`test/stackchan_protocol_test.rb` の末尾に append：
```ruby
class FaceBaseMouthTest < Test::Unit::TestCase
  def setup
    @display = FakeDisplay.new
    @face = StackchanProtocol::Face::Base.new
  end

  def test_draw_mouth_emits_two_lines
    @face.draw_mouth(@display, 0)
    line_calls = @display.calls.select { |c| c.first == :draw_line }
    assert_equal 2, line_calls.size
  end

  def test_delta_y_zero_draws_straight_mouth
    @face.draw_mouth(@display, 0)
    # left segment: (115, 146) -> (160, 146)
    assert_equal [115, 146, 160, 146, ILI9342::Color::WHITE], @display.calls[0].last
    # right segment: (160, 146) -> (205, 146)
    assert_equal [160, 146, 205, 146, ILI9342::Color::WHITE], @display.calls[1].last
  end

  def test_positive_delta_y_lifts_corners
    @face.draw_mouth(@display, 8)
    # corner_y = 146 - 8 = 138
    assert_equal [115, 138, 160, 146, ILI9342::Color::WHITE], @display.calls[0].last
    assert_equal [160, 146, 205, 138, ILI9342::Color::WHITE], @display.calls[1].last
  end
end
```

- [ ] **Step 2: rake test で fail を確認**

Run:
```bash
cd mrbgems/picoruby-stackchan-protocol && bundle exec rake test
```

Expected: FAIL — `NoMethodError: undefined method 'draw_mouth'`.

- [ ] **Step 3: `Face::Base#draw_mouth` を実装**

`mrblib/stackchan_protocol.rb` の `class Base` 内、`draw_eyes` の下に追加：
```ruby
      def draw_mouth(display, delta_y)
        cx = MOUTH_CX
        cy = MOUTH_CY
        hw = MOUTH_HALF_WIDTH
        left_x   = cx - hw
        right_x  = cx + hw
        corner_y = cy - delta_y
        display.draw_line(left_x, corner_y, cx,      cy,       MOUTH_COLOR)
        display.draw_line(cx,     cy,       right_x, corner_y, MOUTH_COLOR)
      end
```

- [ ] **Step 4: rake test で green**

Run:
```bash
cd mrbgems/picoruby-stackchan-protocol && bundle exec rake test
```

Expected: `14 tests, 24 assertions, 0 failures, 0 errors` (前 11 + 3 new).

- [ ] **Step 5: 中間 commit**

```bash
git add mrbgems/picoruby-stackchan-protocol/mrblib/stackchan_protocol.rb mrbgems/picoruby-stackchan-protocol/test/stackchan_protocol_test.rb
git commit -m "feat(stackchan-protocol): Face::Base#draw_mouth"
```

---

### Task 6: `Face::Neutral` / `Smile` / `Joy` subclasses + `Base#draw` (TDD)

spec §6.3 に従い 3 subclass それぞれ `DELTA_Y` 定数を持つ。`Base#draw(display)` は `display.fill(BACKGROUND_COLOR) → draw_eyes → draw_mouth(display, self.class::DELTA_Y)` を順次呼ぶ。DELTA_Y は既存 examples の値を踏襲：neutral=0, smile=8, joy=18。

- [ ] **Step 1: 失敗テストを追加**

`test/stackchan_protocol_test.rb` の末尾に append：
```ruby
class FaceSubclassesTest < Test::Unit::TestCase
  def setup
    @display = FakeDisplay.new
  end

  def test_neutral_delta_y_is_zero
    assert_equal 0, StackchanProtocol::Face::Neutral::DELTA_Y
  end

  def test_smile_delta_y_is_eight
    assert_equal 8, StackchanProtocol::Face::Smile::DELTA_Y
  end

  def test_joy_delta_y_is_eighteen
    assert_equal 18, StackchanProtocol::Face::Joy::DELTA_Y
  end

  def test_draw_starts_with_black_fill
    StackchanProtocol::Face::Neutral.new.draw(@display)
    assert_equal [:fill, [ILI9342::Color::BLACK]], @display.calls.first
  end

  def test_draw_sequence_is_fill_then_two_eyes_then_two_mouth_lines
    StackchanProtocol::Face::Smile.new.draw(@display)
    methods = @display.calls.map(&:first)
    assert_equal [:fill, :draw_ellipse, :draw_ellipse, :draw_line, :draw_line], methods
  end

  def test_smile_uses_delta_y_eight_for_mouth
    StackchanProtocol::Face::Smile.new.draw(@display)
    # mouth left line: (115, 138, 160, 146, WHITE)
    line_calls = @display.calls.select { |c| c.first == :draw_line }
    assert_equal [115, 138, 160, 146, ILI9342::Color::WHITE], line_calls.first.last
  end

  def test_joy_uses_delta_y_eighteen_for_mouth
    StackchanProtocol::Face::Joy.new.draw(@display)
    # corner_y = 146 - 18 = 128
    line_calls = @display.calls.select { |c| c.first == :draw_line }
    assert_equal [115, 128, 160, 146, ILI9342::Color::WHITE], line_calls.first.last
  end
end
```

- [ ] **Step 2: rake test で fail を確認**

Run:
```bash
cd mrbgems/picoruby-stackchan-protocol && bundle exec rake test
```

Expected: FAIL — `NameError: uninitialized constant StackchanProtocol::Face::Neutral`.

- [ ] **Step 3: `Face::Base#draw` + 3 subclass を実装**

`mrblib/stackchan_protocol.rb` の `class Base` 内、`draw_mouth` の下に追加：
```ruby
      def draw(display)
        display.fill(BACKGROUND_COLOR)
        draw_eyes(display)
        draw_mouth(display, self.class::DELTA_Y)
      end
```

`class Base; ... end` の直後（同じ `module Face` 内）に追加：
```ruby
    class Neutral < Base
      DELTA_Y = 0
    end

    class Smile < Base
      DELTA_Y = 8
    end

    class Joy < Base
      DELTA_Y = 18
    end
```

- [ ] **Step 4: rake test で green**

Run:
```bash
cd mrbgems/picoruby-stackchan-protocol && bundle exec rake test
```

Expected: `21 tests, 31 assertions, 0 failures, 0 errors` (前 14 + 7 new).

- [ ] **Step 5: 中間 commit**

```bash
git add mrbgems/picoruby-stackchan-protocol/mrblib/stackchan_protocol.rb mrbgems/picoruby-stackchan-protocol/test/stackchan_protocol_test.rb
git commit -m "feat(stackchan-protocol): Face::Neutral/Smile/Joy with Base#draw template"
```

---

## Phase C: StackChan 側 mrbgem — Dispatcher (TDD)

### Task 7: `Dispatcher#handle_byte` の vocabulary 解釈 (TDD)

spec §5.2 の vocabulary：`'0'`→neutral / `'1'`→smile / `'2'`→joy / それ以外 → `STDOUT.write('?')`。Dispatcher は display を constructor で受け、stdin/stdout は default `$stdin`/`$stdout` (テスト時は injection 可)。

- [ ] **Step 1: 失敗テストを追加**

`test/stackchan_protocol_test.rb` の末尾に append：
```ruby
class DispatcherHandleByteTest < Test::Unit::TestCase
  def setup
    @display = FakeDisplay.new
    @stdout  = FakeStdout.new
    @dispatcher = StackchanProtocol::Dispatcher.new(
      display: @display,
      stdin:   FakeStdin.new(""),
      stdout:  @stdout
    )
  end

  def test_byte_zero_draws_neutral
    @dispatcher.handle_byte("0")
    methods = @display.calls.map(&:first)
    assert_equal [:fill, :draw_ellipse, :draw_ellipse, :draw_line, :draw_line], methods
    # mouth corner_y = 146 (delta_y = 0)
    line = @display.calls.select { |c| c.first == :draw_line }.first.last
    assert_equal 146, line[1]
  end

  def test_byte_one_draws_smile
    @dispatcher.handle_byte("1")
    line = @display.calls.select { |c| c.first == :draw_line }.first.last
    assert_equal 138, line[1]  # 146 - 8
  end

  def test_byte_two_draws_joy
    @dispatcher.handle_byte("2")
    line = @display.calls.select { |c| c.first == :draw_line }.first.last
    assert_equal 128, line[1]  # 146 - 18
  end

  def test_valid_byte_does_not_write_error
    @dispatcher.handle_byte("0")
    assert_equal [], @stdout.writes
  end
end
```

- [ ] **Step 2: rake test で fail を確認**

Run:
```bash
cd mrbgems/picoruby-stackchan-protocol && bundle exec rake test
```

Expected: FAIL — `NameError: uninitialized constant StackchanProtocol::Dispatcher`.

- [ ] **Step 3: `Dispatcher` クラスを実装**

`mrblib/stackchan_protocol.rb` の `module StackchanProtocol` 直下、`module Face` の下に追加：
```ruby
  class Dispatcher
    FACES = {
      "0" => Face::Neutral,
      "1" => Face::Smile,
      "2" => Face::Joy,
    }

    ERROR_BYTE = "?"

    def initialize(display:, stdin: $stdin, stdout: $stdout)
      @display = display
      @stdin   = stdin
      @stdout  = stdout
    end

    def handle_byte(byte)
      face_class = FACES[byte]
      if face_class
        face_class.new.draw(@display)
      else
        @stdout.write(ERROR_BYTE)
      end
    end
  end
```

- [ ] **Step 4: rake test で green**

Run:
```bash
cd mrbgems/picoruby-stackchan-protocol && bundle exec rake test
```

Expected: `25 tests, 39 assertions, 0 failures, 0 errors` (前 21 + 4 new).

- [ ] **Step 5: 中間 commit**

```bash
git add mrbgems/picoruby-stackchan-protocol/mrblib/stackchan_protocol.rb mrbgems/picoruby-stackchan-protocol/test/stackchan_protocol_test.rb
git commit -m "feat(stackchan-protocol): Dispatcher#handle_byte vocabulary"
```

---

### Task 8: `Dispatcher#handle_byte` 未知 byte で `'?'` 返却 (TDD)

spec §5.4：未定義 byte（`\r`/`\n`/`'9'` 含む）は全部 `'?'`。

- [ ] **Step 1: 失敗テストを追加**

`test/stackchan_protocol_test.rb` 内 `class DispatcherHandleByteTest` に追加：
```ruby
  def test_unknown_byte_writes_question_mark
    @dispatcher.handle_byte("9")
    assert_equal ["?"], @stdout.writes
  end

  def test_unknown_byte_does_not_draw
    @dispatcher.handle_byte("9")
    assert_equal [], @display.calls
  end

  def test_newline_is_treated_as_unknown
    @dispatcher.handle_byte("\n")
    assert_equal ["?"], @stdout.writes
  end

  def test_carriage_return_is_treated_as_unknown
    @dispatcher.handle_byte("\r")
    assert_equal ["?"], @stdout.writes
  end
```

- [ ] **Step 2: rake test で green を確認 (handle_byte は既に else 分岐で '?' write してるはず)**

Run:
```bash
cd mrbgems/picoruby-stackchan-protocol && bundle exec rake test
```

Expected: `29 tests, 43 assertions, 0 failures, 0 errors`. すでに `else: @stdout.write(ERROR_BYTE)` が Task 7 で実装されてるので、追加テストは全部 pass するはず。

- [ ] **Step 3: 中間 commit**

```bash
git add mrbgems/picoruby-stackchan-protocol/test/stackchan_protocol_test.rb
git commit -m "test(stackchan-protocol): cover unknown-byte error path"
```

---

### Task 9: `Dispatcher#handle_byte` の例外 rescue (TDD)

spec §10：内部例外（描画失敗等）も `'?'` に統合してクラッシュ禁止。

- [ ] **Step 1: 失敗テストを追加**

`test/stackchan_protocol_test.rb` 内 `class DispatcherHandleByteTest` に追加：
```ruby
  def test_display_failure_emits_error_byte
    @display.raise_on_fill = StandardError.new("simulated draw failure")
    @dispatcher.handle_byte("0")
    assert_equal ["?"], @stdout.writes
  end

  def test_display_failure_does_not_propagate
    @display.raise_on_fill = StandardError.new("simulated draw failure")
    assert_nothing_raised do
      @dispatcher.handle_byte("0")
    end
  end
```

- [ ] **Step 2: rake test で fail を確認**

Run:
```bash
cd mrbgems/picoruby-stackchan-protocol && bundle exec rake test
```

Expected: FAIL — `StandardError: simulated draw failure` が rescue されてない。

- [ ] **Step 3: `handle_byte` に rescue を入れる**

`mrblib/stackchan_protocol.rb` の `def handle_byte` を以下に置き換え：
```ruby
    def handle_byte(byte)
      face_class = FACES[byte]
      if face_class
        face_class.new.draw(@display)
      else
        @stdout.write(ERROR_BYTE)
      end
    rescue StandardError
      @stdout.write(ERROR_BYTE)
    end
```

- [ ] **Step 4: rake test で green**

Run:
```bash
cd mrbgems/picoruby-stackchan-protocol && bundle exec rake test
```

Expected: `31 tests, 45 assertions, 0 failures, 0 errors`.

- [ ] **Step 5: 中間 commit**

```bash
git add mrbgems/picoruby-stackchan-protocol/mrblib/stackchan_protocol.rb mrbgems/picoruby-stackchan-protocol/test/stackchan_protocol_test.rb
git commit -m "feat(stackchan-protocol): handle_byte rescues internal errors as '?'"
```

---

### Task 10: `Dispatcher#run` のブロッキング loop (TDD)

spec §5.3：`STDIN.read(1)` で 1 byte ずつ読む loop。host テストは FakeStdin が `nil` を返したら exit する仕様にしてテストハング防止。

- [ ] **Step 1: 失敗テストを追加**

`test/stackchan_protocol_test.rb` の末尾に append：
```ruby
class DispatcherRunTest < Test::Unit::TestCase
  def setup
    @display = FakeDisplay.new
    @stdout  = FakeStdout.new
  end

  def test_run_processes_all_bytes_until_stream_ends
    stdin = FakeStdin.new("012")
    dispatcher = StackchanProtocol::Dispatcher.new(
      display: @display, stdin: stdin, stdout: @stdout
    )
    dispatcher.run
    fills = @display.calls.select { |c| c.first == :fill }
    assert_equal 3, fills.size, "should have drawn 3 faces"
  end

  def test_run_mixes_valid_and_invalid_bytes
    stdin = FakeStdin.new("0X1")
    dispatcher = StackchanProtocol::Dispatcher.new(
      display: @display, stdin: stdin, stdout: @stdout
    )
    dispatcher.run
    fills = @display.calls.select { |c| c.first == :fill }
    assert_equal 2, fills.size
    assert_equal ["?"], @stdout.writes
  end

  def test_run_returns_when_stream_is_empty
    stdin = FakeStdin.new("")
    dispatcher = StackchanProtocol::Dispatcher.new(
      display: @display, stdin: stdin, stdout: @stdout
    )
    assert_nothing_raised { dispatcher.run }
    assert_equal [], @display.calls
    assert_equal [], @stdout.writes
  end
end
```

- [ ] **Step 2: rake test で fail を確認**

Run:
```bash
cd mrbgems/picoruby-stackchan-protocol && bundle exec rake test
```

Expected: FAIL — `NoMethodError: undefined method 'run'`.

- [ ] **Step 3: `Dispatcher#run` を実装**

`mrblib/stackchan_protocol.rb` の `Dispatcher` クラス内、`handle_byte` の下に追加：
```ruby
    def run
      loop do
        byte = @stdin.read(1)
        break if byte.nil?
        handle_byte(byte)
      end
    end
```

- [ ] **Step 4: rake test で green**

Run:
```bash
cd mrbgems/picoruby-stackchan-protocol && bundle exec rake test
```

Expected: `34 tests, 49 assertions, 0 failures, 0 errors`.

- [ ] **Step 5: 中間 commit**

```bash
git add mrbgems/picoruby-stackchan-protocol/mrblib/stackchan_protocol.rb mrbgems/picoruby-stackchan-protocol/test/stackchan_protocol_test.rb
git commit -m "feat(stackchan-protocol): Dispatcher#run blocking loop"
```

---

## Phase D: StackChan 側 mrbgem — 仕上げ (例 / sig / README)

### Task 11: `examples/app.rb` を作成 (実機向け、host テストでは load しない)

spec §6.5 の通り SPI/GPIO/ILI9342 setup + 最初に neutral 顔描画 + Dispatcher.run。ピン番号は `mrbgems/picoruby-ili9342/examples/face_neutral.rb:8-12` と一致させる。

- [ ] **Step 1: `examples/app.rb` を作成**

`mrbgems/picoruby-stackchan-protocol/examples/app.rb`:
```ruby
# examples/app.rb — autostart entry point. Copy this to /home/app.rb on the
# device (via picomodem upload, see docs/STACKCHAN_PROTOCOL_VERIFICATION.md).
#
# Pin layout matches mrbgems/picoruby-ili9342/examples/face_neutral.rb.
# rst_pin / bl_pin are placeholders until AW9523 / AXP2101 drivers exist.

require 'spi'
require 'gpio'
require 'ili9342'
require 'stackchan_protocol'

SCK_PIN  = 36
MOSI_PIN = 37
CS_PIN   = 3
DC_PIN   = 35
RST_PIN  = 1   # placeholder — AW9523 P1.1 routes the real LCD reset
BL_PIN   = 2   # placeholder — AXP2101 routes the real backlight

# NOTE: cs_pin: omitted from SPI.new — driver manages CS manually so the
# cmd→DC change→data window stays in a single CS-low frame.
spi = SPI.new(unit: :ESP32_SPI3_HOST, frequency: 40_000_000,
              sck_pin: SCK_PIN, copi_pin: MOSI_PIN, mode: 2)
display = ILI9342.new(
  spi: spi,
  dc_pin:  GPIO.new(DC_PIN,  GPIO::OUT),
  cs_pin:  GPIO.new(CS_PIN,  GPIO::OUT),
  rst_pin: GPIO.new(RST_PIN, GPIO::OUT),
  bl_pin:  GPIO.new(BL_PIN,  GPIO::OUT),
  width: 320, height: 240, rotation: :landscape
)

# Welcome face before any host command arrives.
StackchanProtocol::Face::Neutral.new.draw(display)

# Make sure '?' is emitted promptly on error.
$stdout.sync = true if $stdout.respond_to?(:sync=)

StackchanProtocol::Dispatcher.new(display: display).run
```

- [ ] **Step 2: host テストはこのファイルを load しない（require 不可）ことを確認**

Run:
```bash
cd mrbgems/picoruby-stackchan-protocol && bundle exec rake test
```

Expected: `34 tests, 49 assertions, 0 failures, 0 errors` — examples/app.rb は test/ 配下でないので Rakefile の test_files に含まれない。

- [ ] **Step 3: 中間 commit**

```bash
git add mrbgems/picoruby-stackchan-protocol/examples/app.rb
git commit -m "feat(stackchan-protocol): examples/app.rb autostart entry"
```

---

### Task 12: `sig/stackchan_protocol.rbs` の型シグネチャ

picoruby-ili9342 の `sig/ili9342.rbs` と同様、最小の RBS。spec §6.3 を反映。

- [ ] **Step 1: `sig/stackchan_protocol.rbs` を作成**

```rbs
module StackchanProtocol
  module Face
    EYE_LEFT_CX: Integer
    EYE_LEFT_CY: Integer
    EYE_RIGHT_CX: Integer
    EYE_RIGHT_CY: Integer
    EYE_RX: Integer
    EYE_RY: Integer
    EYE_COLOR: Integer
    MOUTH_COLOR: Integer
    BACKGROUND_COLOR: Integer
    MOUTH_CX: Integer
    MOUTH_CY: Integer
    MOUTH_HALF_WIDTH: Integer

    class Base
      def draw_eyes: (untyped display) -> void
      def draw_mouth: (untyped display, Integer delta_y) -> void
      def draw: (untyped display) -> void
    end

    class Neutral < Base
      DELTA_Y: Integer
    end

    class Smile < Base
      DELTA_Y: Integer
    end

    class Joy < Base
      DELTA_Y: Integer
    end
  end

  class Dispatcher
    FACES: Hash[String, singleton(Face::Base)]
    ERROR_BYTE: String

    def initialize: (display: untyped, ?stdin: untyped, ?stdout: untyped) -> void
    def handle_byte: (String byte) -> void
    def run: () -> void
  end
end
```

- [ ] **Step 2: 中間 commit**

```bash
git add mrbgems/picoruby-stackchan-protocol/sig/stackchan_protocol.rbs
git commit -m "docs(stackchan-protocol): add RBS signatures"
```

---

### Task 13: `README.md` を本実装内容に更新

- [ ] **Step 1: README を書き換え**

`mrbgems/picoruby-stackchan-protocol/README.md`:
```markdown
# picoruby-stackchan-protocol

StackChan ⇔ PC の USB-serial 1-byte プロトコル ディスパッチャと、neutral / smile / joy 3 表情の手続き的顔描画を提供する PicoRuby mrbgem。

## API

### `StackchanProtocol::Dispatcher`

```ruby
display = ILI9342.new(...)
StackchanProtocol::Dispatcher.new(display: display).run
```

- `STDIN.read(1)` でブロッキング読込
- `'0'` neutral / `'1'` smile / `'2'` joy → 描画
- 上記以外（boot ノイズ `\r\n` 含む）と内部例外 → `STDOUT.write('?')`
- `nil` (EOF) で `run` から return（host テスト用）

### `StackchanProtocol::Face`

`Face::Neutral` / `Face::Smile` / `Face::Joy` — 各クラスに `DELTA_Y` 定数、`#draw(display)` で `fill(BLACK) → 両目 → 口` を順次描画。

## 依存

- `picoruby-ili9342`
- `picoruby-spi` / `picoruby-gpio`（examples/app.rb のみ）

## ホストテスト

```sh
bundle install --path vendor/bundle
bundle exec rake test
```

`test/fake_display.rb` と `test/fake_stdio.rb` で display / stdin / stdout を差し替え。実機検証は `docs/STACKCHAN_PROTOCOL_VERIFICATION.md`。

## 設計

`docs/superpowers/specs/2026-05-14-stackchan-protocol-design.md`
```

- [ ] **Step 2: 中間 commit**

```bash
git add mrbgems/picoruby-stackchan-protocol/README.md
git commit -m "docs(stackchan-protocol): expand README with API and test instructions"
```

---

## Phase E: PC 側 gem — 基本ファイル & テスト基盤

### Task 14: `pc/stackchan-protocol/` 雛形 + gemspec + Gemfile + Rakefile + version.rb

- [ ] **Step 1: ディレクトリ作成**

Run:
```bash
mkdir -p pc/stackchan-protocol/{lib/stackchan_protocol,exe,test}
```

- [ ] **Step 2: `version.rb` を作成**

`pc/stackchan-protocol/lib/stackchan_protocol/version.rb`:
```ruby
module StackchanProtocol
  VERSION = "0.1.0"
end
```

- [ ] **Step 3: `stackchan-protocol.gemspec` を作成**

`pc/stackchan-protocol/stackchan-protocol.gemspec`:
```ruby
require_relative "lib/stackchan_protocol/version"

Gem::Specification.new do |spec|
  spec.name        = "stackchan-protocol"
  spec.version     = StackchanProtocol::VERSION
  spec.authors     = ["bash0C7"]
  spec.summary     = "Host-side client for the StackChan USB-serial 1-byte protocol"
  spec.license     = "MIT"

  spec.files       = Dir["lib/**/*.rb", "exe/*", "README.md"]
  spec.executables = ["stackchan-control"]
  spec.bindir      = "exe"
  spec.require_paths = ["lib"]

  spec.required_ruby_version = ">= 3.1"

  spec.add_dependency "uart", "~> 1.0"

  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "test-unit", "~> 3.6"
end
```

- [ ] **Step 4: `Gemfile` を作成**

`pc/stackchan-protocol/Gemfile`:
```ruby
source "https://rubygems.org"

gemspec
```

- [ ] **Step 5: `Rakefile` を作成**

`pc/stackchan-protocol/Rakefile`:
```ruby
require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList["test/**/*_test.rb"]
  t.verbose = true
end

task default: :test
```

- [ ] **Step 6: `README.md` placeholder を作成（Task 24 で更新）**

`pc/stackchan-protocol/README.md`:
```markdown
# stackchan-protocol (PC side)

Host-side Ruby gem for talking to a StackChan running `picoruby-stackchan-protocol`. See `docs/superpowers/specs/2026-05-14-stackchan-protocol-design.md` for protocol details.
```

- [ ] **Step 7: `bundle install`**

Run:
```bash
cd pc/stackchan-protocol && bundle install --path vendor/bundle
```

Expected: `Bundle complete!`、`Gemfile.lock` 生成。`uart` gem は `ruby-termios` も pull する。

- [ ] **Step 8: `vendor/bundle/` の gitignore を確認**

Run:
```bash
git check-ignore pc/stackchan-protocol/vendor/bundle/
```

Expected: gitignore path 出力。出ないなら `.gitignore` に `pc/*/vendor/bundle/` を追加。

- [ ] **Step 9: empty rake test を回す**

Run:
```bash
cd pc/stackchan-protocol && bundle exec rake test
```

Expected: `0 tests, 0 assertions, 0 failures, 0 errors`.

- [ ] **Step 10: 中間 commit**

```bash
git add pc/stackchan-protocol/
git commit -m "chore(pc/stackchan-protocol): scaffold gem skeleton"
```

---

### Task 15: `FakeUart` mock + test_helper.rb

`tenderlove/uart` の API は `UART.open(port, baud)` で IO-like (read/write/wait_readable/close) を返す。FakeUart は同じ I/F を mimic、read buffer に仕込んだ bytes を返す。`IO.select` 互換のため `to_io` を実装するか、`IO.select` を call せず自前の `ready_to_read?` を使う方針にする — 後者にすると `Client#set_face` のロジックが UART 直叩きから乖離するので、**FakeUart に `wait_readable(timeout)` メソッドを生やす**方針にして `Client` 側も `IO.select` ではなく `uart.wait_readable(timeout)` を呼ぶ。これで Client が IO の有無に依存しない設計になり、本物 UART 側に `wait_readable(timeout)` accessor を生やす（spec §7.4 で言及されてる upstream PR 候補）方針と一致。

- [ ] **Step 1: `test_helper.rb` を作成**

`pc/stackchan-protocol/test/test_helper.rb`:
```ruby
$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
$LOAD_PATH.unshift File.expand_path(".", __dir__)

require "test/unit"
require "fake_uart"
```

- [ ] **Step 2: `FakeUart` を作成**

`pc/stackchan-protocol/test/fake_uart.rb`:
```ruby
# A test double for tenderlove/uart's IO-like object. Records writes, returns
# pre-loaded bytes from #read, and lets the test choose whether #wait_readable
# reports data ready.
class FakeUart
  attr_reader :writes, :wait_readable_calls
  attr_accessor :read_buffer

  def initialize(read_bytes: "")
    @writes = []
    @read_buffer = read_bytes.dup
    @wait_readable_calls = []
    @closed = false
  end

  def write(s)
    @writes << s.to_s
    s.to_s.bytesize
  end

  def read(n)
    bytes = @read_buffer.slice!(0, n)
    bytes.empty? ? nil : bytes
  end

  # Returns self when there's at least one byte buffered, nil otherwise.
  # The `timeout` argument is recorded for assertion; it does not sleep.
  def wait_readable(timeout)
    @wait_readable_calls << timeout
    @read_buffer.empty? ? nil : self
  end

  def close
    @closed = true
  end

  def closed?
    @closed
  end
end
```

- [ ] **Step 3: harness テストを書いて green を確認**

`pc/stackchan-protocol/test/client_test.rb`:
```ruby
require "test_helper"

class FakeUartHarnessTest < Test::Unit::TestCase
  def test_write_records_history
    u = FakeUart.new
    u.write("1")
    assert_equal ["1"], u.writes
  end

  def test_read_returns_buffered_bytes
    u = FakeUart.new(read_bytes: "?X")
    assert_equal "?", u.read(1)
    assert_equal "X", u.read(1)
    assert_nil u.read(1)
  end

  def test_wait_readable_returns_self_when_buffer_nonempty
    u = FakeUart.new(read_bytes: "?")
    assert_same u, u.wait_readable(0.5)
  end

  def test_wait_readable_returns_nil_on_empty_buffer
    u = FakeUart.new
    assert_nil u.wait_readable(0.5)
  end

  def test_wait_readable_records_timeout_arg
    u = FakeUart.new(read_bytes: "?")
    u.wait_readable(0.42)
    assert_equal [0.42], u.wait_readable_calls
  end

  def test_close_marks_closed
    u = FakeUart.new
    u.close
    assert u.closed?
  end
end
```

- [ ] **Step 4: rake test で green**

Run:
```bash
cd pc/stackchan-protocol && bundle exec rake test
```

Expected: `6 tests, 6 assertions, 0 failures, 0 errors`.

- [ ] **Step 5: 中間 commit**

```bash
git add pc/stackchan-protocol/test/
git commit -m "test(pc/stackchan-protocol): add FakeUart double"
```

---

## Phase F: PC 側 gem — Client 実装 (TDD)

### Task 16: `face_table.rb` の `FACE_BYTES` 定数 (TDD)

- [ ] **Step 1: 失敗テストを追加**

`pc/stackchan-protocol/test/client_test.rb` の末尾に append：
```ruby
require "stackchan_protocol"

class FaceTableTest < Test::Unit::TestCase
  def test_neutral_maps_to_zero
    assert_equal "0", StackchanProtocol::FACE_BYTES.fetch(:neutral)
  end

  def test_smile_maps_to_one
    assert_equal "1", StackchanProtocol::FACE_BYTES.fetch(:smile)
  end

  def test_joy_maps_to_two
    assert_equal "2", StackchanProtocol::FACE_BYTES.fetch(:joy)
  end

  def test_table_is_frozen
    assert_predicate StackchanProtocol::FACE_BYTES, :frozen?
  end

  def test_unknown_face_raises_key_error
    assert_raises(KeyError) { StackchanProtocol::FACE_BYTES.fetch(:rage) }
  end
end
```

- [ ] **Step 2: rake test で fail を確認**

Run:
```bash
cd pc/stackchan-protocol && bundle exec rake test
```

Expected: FAIL — `LoadError: cannot load such file -- stackchan_protocol`.

- [ ] **Step 3: `lib/stackchan_protocol.rb` と `face_table.rb` を実装**

`pc/stackchan-protocol/lib/stackchan_protocol.rb`:
```ruby
require_relative "stackchan_protocol/version"
require_relative "stackchan_protocol/face_table"
```

`pc/stackchan-protocol/lib/stackchan_protocol/face_table.rb`:
```ruby
module StackchanProtocol
  FACE_BYTES = {
    neutral: "0",
    smile:   "1",
    joy:     "2",
  }.freeze
end
```

- [ ] **Step 4: rake test で green**

Run:
```bash
cd pc/stackchan-protocol && bundle exec rake test
```

Expected: `11 tests, 11 assertions, 0 failures, 0 errors`.

- [ ] **Step 5: 中間 commit**

```bash
git add pc/stackchan-protocol/lib/
git commit -m "feat(pc/stackchan-protocol): FACE_BYTES vocabulary table"
```

---

### Task 17: `Client#initialize` + `Client.open` (TDD)

`Client.open(port:, ...)` block-yield で UART を open/close する。tenderlove/uart の API は `UART.open(port, baud)` だが、テストでは UART クラス自体を `uart_class:` キーワードで注入できるようにする（DI）。

- [ ] **Step 1: 失敗テストを追加**

`test/client_test.rb` の末尾に append：
```ruby
class ClientInitializeTest < Test::Unit::TestCase
  def test_stores_port_and_baud
    client = StackchanProtocol::Client.new(port: "/dev/cu.fake")
    assert_equal "/dev/cu.fake", client.port
    assert_equal 115_200, client.baud
  end

  def test_accepts_custom_baud
    client = StackchanProtocol::Client.new(port: "/dev/cu.fake", baud: 9_600)
    assert_equal 9_600, client.baud
  end

  def test_default_ack_timeout
    client = StackchanProtocol::Client.new(port: "/dev/cu.fake")
    assert_equal 0.5, client.ack_timeout
  end
end

class ClientOpenTest < Test::Unit::TestCase
  def test_open_invokes_uart_class_with_port_and_baud
    fake_uart_class = Class.new do
      class << self
        attr_reader :opened_with
      end

      def self.open(port, baud)
        @opened_with = [port, baud]
        u = FakeUart.new
        block_given? ? yield(u).tap { u.close } : u
      end
    end

    client = StackchanProtocol::Client.new(
      port: "/dev/cu.fake", baud: 115_200, uart_class: fake_uart_class
    )
    client.open { |_serial| :ok }
    assert_equal ["/dev/cu.fake", 115_200], fake_uart_class.opened_with
  end

  def test_open_yields_serial_to_block
    fake_uart_class = Class.new do
      def self.open(_port, _baud)
        u = FakeUart.new
        yield u
      ensure
        u&.close
      end
    end

    captured = nil
    client = StackchanProtocol::Client.new(
      port: "/dev/cu.fake", uart_class: fake_uart_class
    )
    client.open { |serial| captured = serial }
    assert_kind_of FakeUart, captured
  end
end
```

- [ ] **Step 2: rake test で fail を確認**

Run:
```bash
cd pc/stackchan-protocol && bundle exec rake test
```

Expected: FAIL — `NameError: uninitialized constant StackchanProtocol::Client`.

- [ ] **Step 3: `client.rb` の最小実装**

`pc/stackchan-protocol/lib/stackchan_protocol/client.rb`:
```ruby
require "uart"

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
  end
end
```

`pc/stackchan-protocol/lib/stackchan_protocol.rb` を更新（client require 追加）：
```ruby
require_relative "stackchan_protocol/version"
require_relative "stackchan_protocol/face_table"
require_relative "stackchan_protocol/client"
```

- [ ] **Step 4: rake test で green**

Run:
```bash
cd pc/stackchan-protocol && bundle exec rake test
```

Expected: `16 tests, 16 assertions, 0 failures, 0 errors`.

- [ ] **Step 5: 中間 commit**

```bash
git add pc/stackchan-protocol/lib/ pc/stackchan-protocol/test/
git commit -m "feat(pc/stackchan-protocol): Client#initialize and Client#open"
```

---

### Task 18: `Client#raw_send` (TDD)

セッション内で開いた serial に対し生 byte 1 つを送信する debug API。実用面でも `set_face` を組み立てる土台になる。

- [ ] **Step 1: 失敗テストを追加**

`test/client_test.rb` の末尾に append：
```ruby
class ClientRawSendTest < Test::Unit::TestCase
  def setup
    @fake_uart = FakeUart.new
    @fake_uart_class = stub_uart_class(@fake_uart)
    @client = StackchanProtocol::Client.new(
      port: "/dev/cu.fake", uart_class: @fake_uart_class
    )
  end

  def test_raw_send_writes_single_byte
    @client.open do |serial|
      @client.raw_send(serial, "9")
    end
    assert_equal ["9"], @fake_uart.writes
  end

  private

  def stub_uart_class(fake)
    Class.new do
      define_singleton_method(:open) do |_port, _baud, &block|
        block.call(fake)
      end
    end
  end
end
```

- [ ] **Step 2: rake test で fail を確認**

Run:
```bash
cd pc/stackchan-protocol && bundle exec rake test
```

Expected: FAIL — `NoMethodError: undefined method 'raw_send'`.

- [ ] **Step 3: `Client#raw_send` を実装**

`lib/stackchan_protocol/client.rb` の `class Client` 内、`open` の下に追加：
```ruby
    def raw_send(serial, byte)
      serial.write(byte)
    end
```

- [ ] **Step 4: rake test で green**

Run:
```bash
cd pc/stackchan-protocol && bundle exec rake test
```

Expected: `17 tests, 17 assertions, 0 failures, 0 errors`.

- [ ] **Step 5: 中間 commit**

```bash
git add pc/stackchan-protocol/lib/stackchan_protocol/client.rb pc/stackchan-protocol/test/client_test.rb
git commit -m "feat(pc/stackchan-protocol): Client#raw_send"
```

---

### Task 19: `Client#set_face` の success path (TDD)

`set_face(serial, name)` 動作：
1. `FACE_BYTES.fetch(name)` で byte 取得（未知 name は KeyError、Task 22）
2. `serial.write(byte)`
3. `serial.wait_readable(@ack_timeout)` で ack を待つ
4. nil (タイムアウト) なら success とみなして return nil
5. ready なら `serial.read(1)` → `'?'` なら DeviceError、それ以外は noise として無視

このタスクでは 1〜2 と 3 のタイムアウト分岐だけ。`'?'` 分岐は Task 20、`KeyError` は Task 21。

- [ ] **Step 1: 失敗テストを追加**

`test/client_test.rb` の末尾に append：
```ruby
class ClientSetFaceSuccessTest < Test::Unit::TestCase
  def setup
    @fake_uart = FakeUart.new  # 空 read_buffer = ack 来ない = タイムアウト = success
    @fake_uart_class = Class.new do
      def self.open(_port, _baud, &block); block.call(@_fake); end
      class << self; attr_accessor :_fake; end
    end
    @fake_uart_class._fake = @fake_uart
    @client = StackchanProtocol::Client.new(
      port: "/dev/cu.fake", ack_timeout: 0.1, uart_class: @fake_uart_class
    )
  end

  def test_set_face_writes_smile_byte
    @client.open { |s| @client.set_face(s, :smile) }
    assert_equal ["1"], @fake_uart.writes
  end

  def test_set_face_writes_neutral_byte
    @client.open { |s| @client.set_face(s, :neutral) }
    assert_equal ["0"], @fake_uart.writes
  end

  def test_set_face_writes_joy_byte
    @client.open { |s| @client.set_face(s, :joy) }
    assert_equal ["2"], @fake_uart.writes
  end

  def test_set_face_returns_nil_on_ack_timeout
    result = @client.open { |s| @client.set_face(s, :smile) }
    assert_nil result
  end

  def test_set_face_uses_configured_ack_timeout
    @client.open { |s| @client.set_face(s, :smile) }
    assert_equal [0.1], @fake_uart.wait_readable_calls
  end
end
```

- [ ] **Step 2: rake test で fail を確認**

Run:
```bash
cd pc/stackchan-protocol && bundle exec rake test
```

Expected: FAIL — `NoMethodError: undefined method 'set_face'`.

- [ ] **Step 3: `Client#set_face` を実装**

`lib/stackchan_protocol/client.rb` の `raw_send` の下に追加：
```ruby
    def set_face(serial, name)
      byte = FACE_BYTES.fetch(name)
      serial.write(byte)
      ready = serial.wait_readable(@ack_timeout)
      return nil if ready.nil?
      ack = serial.read(1)
      raise DeviceError, "device reported '?' for face=#{name}" if ack == "?"
      nil
    end
```

- [ ] **Step 4: rake test で green**

Run:
```bash
cd pc/stackchan-protocol && bundle exec rake test
```

Expected: `22 tests, 22 assertions, 0 failures, 0 errors`.

- [ ] **Step 5: 中間 commit**

```bash
git add pc/stackchan-protocol/lib/stackchan_protocol/client.rb pc/stackchan-protocol/test/client_test.rb
git commit -m "feat(pc/stackchan-protocol): Client#set_face success and timeout"
```

---

### Task 20: `Client#set_face` の `DeviceError` パス (TDD)

ack で `'?'` が来たら `DeviceError` raise。

- [ ] **Step 1: 失敗テストを追加**

`test/client_test.rb` の末尾に append：
```ruby
class ClientSetFaceDeviceErrorTest < Test::Unit::TestCase
  def setup
    @fake_uart = FakeUart.new(read_bytes: "?")
    @fake_uart_class = Class.new do
      def self.open(_port, _baud, &block); block.call(@_fake); end
      class << self; attr_accessor :_fake; end
    end
    @fake_uart_class._fake = @fake_uart
    @client = StackchanProtocol::Client.new(
      port: "/dev/cu.fake", ack_timeout: 0.1, uart_class: @fake_uart_class
    )
  end

  def test_set_face_raises_device_error_on_question_mark
    assert_raises(StackchanProtocol::DeviceError) do
      @client.open { |s| @client.set_face(s, :smile) }
    end
  end

  def test_set_face_consumes_byte_before_raising
    begin
      @client.open { |s| @client.set_face(s, :smile) }
    rescue StackchanProtocol::DeviceError
      # expected
    end
    assert_empty @fake_uart.read_buffer
  end

  def test_set_face_ignores_non_question_noise
    @fake_uart.read_buffer = "X"
    result = nil
    assert_nothing_raised do
      result = @client.open { |s| @client.set_face(s, :smile) }
    end
    assert_nil result
  end
end
```

- [ ] **Step 2: rake test で green を確認 (Task 19 の実装で既に network条件 `ack == "?"` → raise になっているはず)**

Run:
```bash
cd pc/stackchan-protocol && bundle exec rake test
```

Expected: `25 tests, 24 assertions, 0 failures, 0 errors`. 既に Task 19 の実装で raise 分岐がある。

- [ ] **Step 3: 中間 commit**

```bash
git add pc/stackchan-protocol/test/client_test.rb
git commit -m "test(pc/stackchan-protocol): cover Client#set_face DeviceError and noise"
```

---

### Task 21: `Client#set_face` の `KeyError` パス (TDD)

未知の face symbol → `FACE_BYTES.fetch` が KeyError を投げる。明示テストでカバレッジ確保。

- [ ] **Step 1: 失敗テストを追加**

`test/client_test.rb` の末尾に append：
```ruby
class ClientSetFaceKeyErrorTest < Test::Unit::TestCase
  def setup
    @fake_uart = FakeUart.new
    @fake_uart_class = Class.new do
      def self.open(_port, _baud, &block); block.call(@_fake); end
      class << self; attr_accessor :_fake; end
    end
    @fake_uart_class._fake = @fake_uart
    @client = StackchanProtocol::Client.new(
      port: "/dev/cu.fake", uart_class: @fake_uart_class
    )
  end

  def test_unknown_face_raises_key_error
    assert_raises(KeyError) do
      @client.open { |s| @client.set_face(s, :rage) }
    end
  end

  def test_unknown_face_does_not_write_anything
    begin
      @client.open { |s| @client.set_face(s, :rage) }
    rescue KeyError
      # expected
    end
    assert_equal [], @fake_uart.writes
  end
end
```

- [ ] **Step 2: rake test で green (既に `FACE_BYTES.fetch` で KeyError なるはず)**

Run:
```bash
cd pc/stackchan-protocol && bundle exec rake test
```

Expected: `27 tests, 26 assertions, 0 failures, 0 errors`.

- [ ] **Step 3: 中間 commit**

```bash
git add pc/stackchan-protocol/test/client_test.rb
git commit -m "test(pc/stackchan-protocol): cover unknown face symbol path"
```

---

### Task 22: `Client#drain` (TDD)

R2P2 boot ログを吸い出す API。`wait_readable(0)` を timeout 0 で polling し、データある限り `read` し続ける。`timeout:` キーワードで全体タイムアウトを区切る（壁時計 `Process.clock_gettime` 比較）。

- [ ] **Step 1: 失敗テストを追加**

`test/client_test.rb` の末尾に append：
```ruby
class ClientDrainTest < Test::Unit::TestCase
  def setup
    @fake_uart = FakeUart.new(read_bytes: "R2P2 banner\r\n$ ")
    @fake_uart_class = Class.new do
      def self.open(_port, _baud, &block); block.call(@_fake); end
      class << self; attr_accessor :_fake; end
    end
    @fake_uart_class._fake = @fake_uart
    @client = StackchanProtocol::Client.new(
      port: "/dev/cu.fake", uart_class: @fake_uart_class
    )
  end

  def test_drain_returns_buffered_string
    drained = @client.open { |s| @client.drain(s, timeout: 0.05) }
    assert_equal "R2P2 banner\r\n$ ", drained
  end

  def test_drain_returns_empty_string_when_nothing_buffered
    @fake_uart.read_buffer = ""
    drained = @client.open { |s| @client.drain(s, timeout: 0.05) }
    assert_equal "", drained
  end
end
```

- [ ] **Step 2: rake test で fail**

Run:
```bash
cd pc/stackchan-protocol && bundle exec rake test
```

Expected: FAIL — `NoMethodError: undefined method 'drain'`.

- [ ] **Step 3: `Client#drain` を実装**

`lib/stackchan_protocol/client.rb` の `set_face` の下に追加：
```ruby
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
```

- [ ] **Step 4: FakeUart の `read` を `read(n)` で n bytes 取れるよう修正（既に `slice!(0, n)` なので OK のはず、再確認）**

`test/fake_uart.rb` の `read` を確認：すでに `@read_buffer.slice!(0, n)` なので動作するが、empty 時に `nil` を返す挙動が drain の `chunk = serial.read(64) || break` と整合するか確認。

drain は wait_readable が nil を返したら break するので、read が empty 文字列を返すパスは入らない。

- [ ] **Step 5: rake test で green**

Run:
```bash
cd pc/stackchan-protocol && bundle exec rake test
```

Expected: `29 tests, 28 assertions, 0 failures, 0 errors`.

- [ ] **Step 6: 中間 commit**

```bash
git add pc/stackchan-protocol/lib/stackchan_protocol/client.rb pc/stackchan-protocol/test/client_test.rb
git commit -m "feat(pc/stackchan-protocol): Client#drain for boot-log noise"
```

---

## Phase G: PC 側 gem — CLI `stackchan-control` (TDD)

### Task 23: `exe/stackchan-control` の引数 parsing (TDD)

仕様 (spec §7.5)：
- `stackchan-control --port PORT FACE_NAME` (FACE_NAME ∈ neutral/smile/joy)
- `stackchan-control --port PORT raw BYTE` (BYTE は文字列、`9` のように 1 byte)
- `--port` 省略時は env `STACKCHAN_PORT`、それも無ければエラー
- CLI ロジックを test 可能にするため、`StackchanProtocol::CLI.run(argv, env:, client_class: Client)` のような entry point を `lib/stackchan_protocol/cli.rb` に切り出して、`exe/stackchan-control` はそれを呼ぶだけ

- [ ] **Step 1: 失敗テストを追加**

`pc/stackchan-protocol/test/cli_test.rb`:
```ruby
require "test_helper"
require "stackchan_protocol/cli"

class CliArgParsingTest < Test::Unit::TestCase
  def setup
    @fake_uart = FakeUart.new
    @fake_uart_class = Class.new do
      def self.open(_port, _baud, &block); block.call(@_fake); end
      class << self; attr_accessor :_fake; end
    end
    @fake_uart_class._fake = @fake_uart
    @stderr = StringIO.new
  end

  def test_port_from_argv
    StackchanProtocol::CLI.run(
      ["--port", "/dev/cu.test", "neutral"],
      env: {}, uart_class: @fake_uart_class, stderr: @stderr
    )
    assert_equal ["0"], @fake_uart.writes
  end

  def test_port_from_env_when_not_in_argv
    StackchanProtocol::CLI.run(
      ["smile"],
      env: { "STACKCHAN_PORT" => "/dev/cu.fromenv" },
      uart_class: @fake_uart_class, stderr: @stderr
    )
    assert_equal ["1"], @fake_uart.writes
  end

  def test_missing_port_exits_nonzero
    status = StackchanProtocol::CLI.run(
      ["smile"], env: {}, uart_class: @fake_uart_class, stderr: @stderr
    )
    assert_not_equal 0, status
    assert_match(/port/i, @stderr.string)
  end

  def test_missing_command_exits_nonzero
    status = StackchanProtocol::CLI.run(
      ["--port", "/dev/cu.test"],
      env: {}, uart_class: @fake_uart_class, stderr: @stderr
    )
    assert_not_equal 0, status
  end
end
```

`test/test_helper.rb` の末尾に追加 (StringIO 用)：
```ruby
require "stringio"
```

- [ ] **Step 2: rake test で fail**

Run:
```bash
cd pc/stackchan-protocol && bundle exec rake test
```

Expected: FAIL — `LoadError: cannot load such file -- stackchan_protocol/cli`.

- [ ] **Step 3: `lib/stackchan_protocol/cli.rb` を実装**

```ruby
require "optparse"
require_relative "client"

module StackchanProtocol
  module CLI
    module_function

    def run(argv, env: ENV.to_h, uart_class: UART, stderr: $stderr, stdout: $stdout)
      port = nil
      OptionParser.new do |opts|
        opts.on("--port PORT", "Serial port path") { |p| port = p }
      end.parse!(argv)

      port ||= env["STACKCHAN_PORT"]
      unless port
        stderr.puts "error: --port required (or set STACKCHAN_PORT)"
        return 2
      end

      command = argv.shift
      unless command
        stderr.puts "error: command required (neutral/smile/joy/raw <byte>)"
        return 2
      end

      client = Client.new(port: port, uart_class: uart_class)
      begin
        client.open do |serial|
          if command == "raw"
            byte = argv.shift
            unless byte
              stderr.puts "error: raw command requires a byte argument"
              return 2
            end
            client.raw_send(serial, byte)
          else
            client.set_face(serial, command.to_sym)
          end
        end
        0
      rescue DeviceError => e
        stderr.puts "device error: #{e.message}"
        1
      rescue KeyError => e
        stderr.puts "unknown face: #{e.message}"
        2
      end
    end
  end
end
```

- [ ] **Step 4: rake test で green**

Run:
```bash
cd pc/stackchan-protocol && bundle exec rake test
```

Expected: `33 tests, 33 assertions, 0 failures, 0 errors`.

- [ ] **Step 5: 中間 commit**

```bash
git add pc/stackchan-protocol/lib/stackchan_protocol/cli.rb pc/stackchan-protocol/test/cli_test.rb pc/stackchan-protocol/test/test_helper.rb
git commit -m "feat(pc/stackchan-protocol): CLI arg parsing and dispatch"
```

---

### Task 24: `raw` サブコマンド + `DeviceError` の CLI 表示 (TDD)

raw 経路で `'?'` 受信したら exit 1 + stderr。

- [ ] **Step 1: 失敗テストを追加**

`test/cli_test.rb` の末尾に append：
```ruby
class CliRawCommandTest < Test::Unit::TestCase
  def setup
    @fake_uart = FakeUart.new
    @fake_uart_class = Class.new do
      def self.open(_port, _baud, &block); block.call(@_fake); end
      class << self; attr_accessor :_fake; end
    end
    @fake_uart_class._fake = @fake_uart
    @stderr = StringIO.new
  end

  def test_raw_sends_byte
    StackchanProtocol::CLI.run(
      ["--port", "/dev/cu.test", "raw", "9"],
      env: {}, uart_class: @fake_uart_class, stderr: @stderr
    )
    assert_equal ["9"], @fake_uart.writes
  end

  def test_raw_without_byte_exits_nonzero
    status = StackchanProtocol::CLI.run(
      ["--port", "/dev/cu.test", "raw"],
      env: {}, uart_class: @fake_uart_class, stderr: @stderr
    )
    assert_not_equal 0, status
  end
end

class CliDeviceErrorTest < Test::Unit::TestCase
  def test_device_error_exits_one
    fake_uart = FakeUart.new(read_bytes: "?")
    fake_uart_class = Class.new do
      def self.open(_port, _baud, &block); block.call(@_fake); end
      class << self; attr_accessor :_fake; end
    end
    fake_uart_class._fake = fake_uart
    stderr = StringIO.new

    status = StackchanProtocol::CLI.run(
      ["--port", "/dev/cu.test", "smile"],
      env: {}, uart_class: fake_uart_class, stderr: stderr
    )
    assert_equal 1, status
    assert_match(/device error/i, stderr.string)
  end
end

class CliUnknownFaceTest < Test::Unit::TestCase
  def test_unknown_face_exits_two
    fake_uart = FakeUart.new
    fake_uart_class = Class.new do
      def self.open(_port, _baud, &block); block.call(@_fake); end
      class << self; attr_accessor :_fake; end
    end
    fake_uart_class._fake = fake_uart
    stderr = StringIO.new

    status = StackchanProtocol::CLI.run(
      ["--port", "/dev/cu.test", "rage"],
      env: {}, uart_class: fake_uart_class, stderr: stderr
    )
    assert_equal 2, status
    assert_match(/unknown face/i, stderr.string)
  end
end
```

- [ ] **Step 2: rake test で green を確認 (Task 23 の実装で既にカバー済みのはず)**

Run:
```bash
cd pc/stackchan-protocol && bundle exec rake test
```

Expected: `37 tests, 38 assertions, 0 failures, 0 errors`. 既存 CLI ロジックで rescue + raw 分岐が動くはず。fail するなら Task 23 の cli.rb を見直す。

- [ ] **Step 3: 中間 commit**

```bash
git add pc/stackchan-protocol/test/cli_test.rb
git commit -m "test(pc/stackchan-protocol): cover CLI raw, DeviceError, unknown face"
```

---

### Task 25: `exe/stackchan-control` 実行ファイル

CLI ロジックは Task 23 で `lib/` に既出。実行ファイルは shebang + 1 行 invocation のみ。

- [ ] **Step 1: `exe/stackchan-control` を作成**

```ruby
#!/usr/bin/env ruby

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "stackchan_protocol/cli"

exit StackchanProtocol::CLI.run(ARGV)
```

- [ ] **Step 2: 実行権限を付与**

Run:
```bash
chmod +x pc/stackchan-protocol/exe/stackchan-control
```

- [ ] **Step 3: bundle exec で smoke test（実機なし、port 未指定で exit 2 を確認）**

Run:
```bash
cd pc/stackchan-protocol && bundle exec exe/stackchan-control smile 2>&1; echo "exit=$?"
```

Expected: `error: --port required ...` + `exit=2`. tenderlove/uart を実 port なしで触らないことを確認。

- [ ] **Step 4: 中間 commit**

```bash
git add pc/stackchan-protocol/exe/stackchan-control
git commit -m "feat(pc/stackchan-protocol): exe/stackchan-control entry"
```

---

### Task 26: PC 側 `README.md` を本実装内容に更新

- [ ] **Step 1: README を書き換え**

`pc/stackchan-protocol/README.md`:
```markdown
# stackchan-protocol (PC side)

Host-side Ruby gem for talking to a StackChan running `picoruby-stackchan-protocol`. Sends 1-byte commands over USB-serial; receives `'?'` (one byte) on device error.

## Install

```sh
cd pc/stackchan-protocol
bundle install --path vendor/bundle
```

## CLI

```sh
bundle exec stackchan-control --port /dev/cu.usbmodem1101 neutral
bundle exec stackchan-control --port /dev/cu.usbmodem1101 smile
bundle exec stackchan-control --port /dev/cu.usbmodem1101 joy
bundle exec stackchan-control --port /dev/cu.usbmodem1101 raw 9   # forces '?' path
```

`--port` 省略時は env `STACKCHAN_PORT` を見る。

Exit codes:
- 0: success (ack timeout 内に `'?'` が来なかった)
- 1: device error (`'?'` が来た)
- 2: usage error (port 未指定、未知 face、引数不足)

## Library

```ruby
require "stackchan_protocol"

client = StackchanProtocol::Client.new(port: "/dev/cu.usbmodem1101")
client.open do |serial|
  client.drain(serial, timeout: 1.0)   # absorb boot log
  client.set_face(serial, :smile)
rescue StackchanProtocol::DeviceError => e
  warn "device: #{e.message}"
end
```

## Tests

```sh
bundle exec rake test
```

FakeUart で UART クラスを差し替えるので実機不要。実機検証は `docs/STACKCHAN_PROTOCOL_VERIFICATION.md`。

## 設計

`docs/superpowers/specs/2026-05-14-stackchan-protocol-design.md`
```

- [ ] **Step 2: 中間 commit**

```bash
git add pc/stackchan-protocol/README.md
git commit -m "docs(pc/stackchan-protocol): expand README"
```

---

## Phase H: R2P2-ESP32 build 統合

### Task 27: `bash0C7/R2P2-ESP32` の build_config に conf.gem を追加

spec §6.6 の通り、`xtensa-esp-picoruby.rb` に 1 行追加。これは別リポジトリの編集なので、stackchan-picoruby 側 git では追跡されない。R2P2-ESP32 側に新 branch を切るか、既存 `feature/cores3-stackchan` に積むかは、隣リポジトリの状態を確認して判断。

- [ ] **Step 1: R2P2-ESP32 側の branch 状態を確認**

Run:
```bash
cd ../../bash0C7/R2P2-ESP32 && git status && git branch --show-current
```

Expected: `feature/cores3-stackchan` branch にいて clean。ili9342 の `conf.gem path:` が既に入ってる前提（HARDWARE_VERIFICATION.md より）。

- [ ] **Step 2: `xtensa-esp-picoruby.rb` を確認**

Run:
```bash
grep -n "conf.gem" ../../bash0C7/R2P2-ESP32/components/picoruby-esp32/build_config/xtensa-esp-picoruby.rb | head -20
```

Expected: 既存の `conf.gem path: '...picoruby-ili9342'` 行が見える。

- [ ] **Step 3: 1 行追加（ili9342 行の直下）**

`bash0C7/R2P2-ESP32/components/picoruby-esp32/build_config/xtensa-esp-picoruby.rb` で、既存の picoruby-ili9342 行を見つけて、その直下に追加：
```ruby
  conf.gem path: '/Users/bash/dev/src/github.com/m5stack/stackchan-picoruby/mrbgems/picoruby-stackchan-protocol'
```

- [ ] **Step 4: R2P2-ESP32 側で commit**

Run:
```bash
cd ../../bash0C7/R2P2-ESP32
git add components/picoruby-esp32/build_config/xtensa-esp-picoruby.rb
git commit -m "feat(build): wire picoruby-stackchan-protocol mrbgem"
```

Note: stackchan-picoruby 側の git tree からは追跡されない（隣リポジトリの変更）。stackchan-picoruby 側の commit には含めない。

- [ ] **Step 5: stackchan-picoruby 側に戻る**

Run:
```bash
cd /Users/bash/dev/src/github.com/m5stack/stackchan-picoruby
```

---

## Phase I: 検証 doc + root README 更新

### Task 28: `docs/STACKCHAN_PROTOCOL_VERIFICATION.md` を作成

display 側の `docs/HARDWARE_VERIFICATION.md` の構造を踏襲。phase ごとに分けて、display と統合した実機検証手順を提示。

- [ ] **Step 1: `docs/STACKCHAN_PROTOCOL_VERIFICATION.md` を作成**

```markdown
# Hardware verification — stackchan-protocol

Manual steps to verify `picoruby-stackchan-protocol` (StackChan side) and
`pc/stackchan-protocol` (PC side) on a real M5Stack CoreS3. All host-side
unit tests pass under `bundle exec rake test`; this doc covers what host
tests cannot — real ILI9342 panel rendering, autostart of `/home/app.rb`,
and serial round-tripping over USB-CDC.

Run these in a session with:
- ESP-IDF v5.4 sourced
- M5Stack CoreS3 connected via USB-C → `/dev/cu.usbmodem1101` enumerated
- `bash0C7/R2P2-ESP32` checked out at the branch where the
  `picoruby-stackchan-protocol` `conf.gem path:` is wired in
  (Task 27 of `docs/superpowers/plans/2026-05-14-stackchan-protocol.md`)
- This repository on branch `feature/stackchan-display-bringup` (or wherever
  Tasks 1–26 of the same plan were merged)

## Prerequisites carried over from display bring-up

The pending phases of `docs/HARDWARE_VERIFICATION.md` are not duplicated
here. **You must successfully complete Phases 1–3 of that doc first**
(vanilla R2P2 boots, `require 'ili9342'` works, `d.fill(0x0000)` blanks
the screen). The phases below assume those checkpoints are green.

## Phase 1 — Build & flash with both mrbgems wired

```bash
cd /Users/bash/dev/src/github.com/m5stack/stackchan-picoruby
rake r2p2:build_flash
```

Pass criterion: `flash complete` in `tmp/longrun/build_flash.log` and CoreS3
reboots into the R2P2 banner.

## Phase 2 — Autostart smoke test (Goal §2 item 1)

1. Open `https://picoruby.org/terminal` in Chrome/Edge, baud 115200,
   port `/dev/cu.usbmodem1101`, connect.
2. In the terminal's `path-input` field, type `/home/app.rb`.
3. `Open local file` →
   `mrbgems/picoruby-stackchan-protocol/examples/app.rb` → mode `Plain` →
   `Upload`. Wait for `done` log.
4. Physical reset of CoreS3 (RST button or `rake r2p2:reset`).

Pass criterion: within ~5 s of reset the screen shows a neutral face (two
white round eyes + a straight horizontal mouth) on a black background. No
keyboard interaction needed.

## Phase 3 — PC client install (Goal §2 item 2)

```bash
cd pc/stackchan-protocol
bundle install --path vendor/bundle
```

Pass criterion: `Bundle complete!`. `uart` and its `ruby-termios`
transitive dependency build cleanly.

## Phase 4 — Face switching (Goal §2 items 3-4)

With CoreS3 still on the neutral-face autostart screen:

```bash
cd pc/stackchan-protocol
bundle exec stackchan-control --port /dev/cu.usbmodem1101 smile
```

Pass criterion: within ~1 s the mouth changes to a mild upward V shape
(corner_y = 138, lifted 8 px from neutral). No CLI error output, exit 0.

```bash
bundle exec stackchan-control --port /dev/cu.usbmodem1101 joy
bundle exec stackchan-control --port /dev/cu.usbmodem1101 neutral
```

Pass criterion: face switches to joy (corner_y = 128, lifted 18 px) then
back to neutral. Each call returns exit 0.

## Phase 5 — Error byte round-trip (Goal §2 item 5)

```bash
bundle exec stackchan-control --port /dev/cu.usbmodem1101 raw 9
```

Pass criterion: screen unchanged. CLI prints something like:
```
device error: device reported '?' for face=... (or for raw send)
```
…and exits 1.

If exit is 0 with no stderr, the `'?'` ack path is broken — most likely
StackChan side `STDOUT.write('?')` is buffered. Confirm `$stdout.sync = true`
is in `examples/app.rb` and `examples/app.rb` was re-uploaded.

If `set_face` reports DeviceError after `neutral`/`smile`/`joy` (Phase 4)
when it should be silent, R2P2 boot ASCII is still leaking after autostart
takes STDIN. Try adding `Client#drain` before `set_face`:
```ruby
client.open do |s|
  client.drain(s, timeout: 1.0)
  client.set_face(s, :smile)
end
```
…and patch `exe/stackchan-control` if reproducible.

## Phase 6 — Stability (Goal §2 item 6)

Run 20 face switches in a row:
```bash
for f in smile joy neutral smile joy neutral smile joy neutral smile \
         joy neutral smile joy neutral smile joy neutral smile joy; do
  bundle exec stackchan-control --port /dev/cu.usbmodem1101 $f || exit 1
  sleep 0.3
done
```

Pass criterion: all 20 succeed (exit 0). Face is correct after the loop.
No `irb` / interactive shell on CoreS3 — the autostart loop is the only
consumer of STDIN.

## Open questions to resolve during this verification (spec §11)

| # | Question | Where to check |
|---|---|---|
| R3 | Is `STDIN.read(1)` blocking on PicoRuby 4.0 / R2P2-ESP32? | Phase 2: if face appears immediately at boot before any PC byte is sent, the `Dispatcher#run` loop is spinning — that means `read(1)` returned nil quickly. Should not happen if `STDIN.read(1)` blocks. If it does, add a `Machine.delay_ms(1)` inside the loop or switch to `STDIN.getc`. |
| R4 | Does `$stdout.write('?')` flush in time for PC `IO.select` window? | Phase 5: if `raw 9` doesn't trigger DeviceError, the `'?'` is buffered. `$stdout.sync = true` in `examples/app.rb` is the first remedy. |
| R5 | Does autostart `app.rb` actually own STDIN/STDOUT? | Phase 2: if app.rb never runs (no face appears) but R2P2 banner shows up over PC serial, autostart is not handing the channels over. Re-check `/home/app.rb` was uploaded. |
| R6 | Does R2P2 boot log noise reach the PC after autostart? | Phase 5: if `neutral/smile/joy` produce spurious DeviceError, boot noise is still leaking. Mitigation: `Client#drain` before sending. |

## After successful verification

1. Update `README.md` status table: change `protocol | host-tested,
   hardware-untested` → `working on CoreS3` (or analogous).
2. If R3/R4/R5/R6 surfaced workarounds, fold them into either
   `examples/app.rb` or `Client` defaults and add a regression test on the
   host side.
3. Decide branch fate (merge `feature/stackchan-display-bringup` to `main`
   together with stackchan-protocol, or keep separate per remaining
   bring-up tasks in `HARDWARE_VERIFICATION.md`).
```

- [ ] **Step 2: 中間 commit**

```bash
git add docs/STACKCHAN_PROTOCOL_VERIFICATION.md
git commit -m "docs(stackchan-protocol): add hardware verification procedure"
```

---

### Task 29: root `README.md` の status table を更新

ルート README が無いか確認、無ければ作る、あるなら status table の行を追加。

- [ ] **Step 1: ルート README の存在を確認**

Run:
```bash
ls README.md 2>&1
```

- [ ] **Step 2a: README が存在する場合**

既存の status table（display bring-up plan で作成されたはず）に `protocol` 行を追加：

`README.md` 内の status table のあたりを Edit して、`LCD (ILI9342)` の行の直後あたりに：
```markdown
| protocol (1-byte USB serial)   | host-tested, hardware-untested |
```

…の行を加える。具体的な列フォーマットは既存 table に合わせる。

- [ ] **Step 2b: README が存在しない場合**

最低限の `README.md` を作る：
```markdown
# stackchan-picoruby

M5Stack StackChan を PicoRuby (R2P2-ESP32) で動かす個人プロジェクト。詳細は `CLAUDE.md` と `docs/superpowers/specs/` を参照。

## Status

| Component | Status |
|---|---|
| LCD (ILI9342)                  | host-tested, hardware-untested |
| Face renderer                  | host-tested, hardware-untested |
| protocol (1-byte USB serial)   | host-tested, hardware-untested |

## Layout

- `mrbgems/picoruby-ili9342/` — display driver mrbgem
- `mrbgems/picoruby-stackchan-protocol/` — host-protocol dispatcher mrbgem
- `pc/stackchan-protocol/` — host-side Ruby client + CLI
- `docs/superpowers/{specs,plans}/` — design and execution docs
- `docs/HARDWARE_VERIFICATION.md` — display bring-up real-device checklist
- `docs/STACKCHAN_PROTOCOL_VERIFICATION.md` — protocol real-device checklist
```

- [ ] **Step 3: 中間 commit**

```bash
git add README.md
git commit -m "docs: update root README status table with stackchan-protocol"
```

---

## Phase J: 仕上げ commit / verification

### Task 30: 全体回帰 — 両側 host test を一気に green 確認

- [ ] **Step 1: StackChan 側 host test**

Run:
```bash
cd mrbgems/picoruby-stackchan-protocol && bundle exec rake test 2>&1 | tail -5
```

Expected: `... 0 failures, 0 errors`. テスト数は 30 前後。

- [ ] **Step 2: PC 側 host test**

Run:
```bash
cd ../../pc/stackchan-protocol && bundle exec rake test 2>&1 | tail -5
```

Expected: `... 0 failures, 0 errors`. テスト数は 35 前後。

- [ ] **Step 3: stackchan-picoruby ルートに戻る**

Run:
```bash
cd /Users/bash/dev/src/github.com/m5stack/stackchan-picoruby
```

- [ ] **Step 4: `git status` で残作業確認**

Run:
```bash
git status
```

Expected: clean working tree (新しい未 commit 変更なし)。あればそれぞれの phase commit に積み直し。

- [ ] **Step 5: 全 commit を `git log --oneline` で確認**

Run:
```bash
git log --oneline -30
```

Expected: ~25 個の小さな commit が並ぶ。conventional commits 風で、`feat/test/docs/chore` が混ざる。

---

### Task 31: 実機検証フェーズ (オプショナル、host 完了後)

Display 側が flash 通る環境ができたら統合実機検証に進む。本 plan の host テストはここまでで完了で、Task 28 の `docs/STACKCHAN_PROTOCOL_VERIFICATION.md` がそのまま実機手順になる。

- [ ] **Step 1: 物理 CoreS3 接続 + ESP-IDF v5.4 source**
- [ ] **Step 2: `rake r2p2:build_flash` を screen 経由で longrun 起動（CLAUDE.md のロングバッチパターン）**
- [ ] **Step 3: `examples/app.rb` を `/home/app.rb` に Upload (picoruby.org/terminal)**
- [ ] **Step 4: physical reset → neutral 顔表示確認**
- [ ] **Step 5: `pc/stackchan-protocol` で `bundle exec stackchan-control --port /dev/cu.usbmodem1101 smile / joy / neutral / raw 9` を順に実行し、`docs/STACKCHAN_PROTOCOL_VERIFICATION.md` Phase 2-6 を pass**
- [ ] **Step 6: 開いてる R3/R4/R5/R6 の解決状況を `docs/STACKCHAN_PROTOCOL_VERIFICATION.md` の末尾 table を埋めて commit**

このタスクは host 完了後の別セッションで実施（branch は同じ）。

---

## Out-of-scope (spec §3.2 を再掲して plan のリマインダー)

以下は本 plan では実装しない（次 spec）：
- BLE-Serial 対応
- IMU/サーボ command vocabulary 拡張
- 接続復帰 / リトライ / レートリミット
- StackChan→PC hello/version
- Foundation Model 連携
- stackchan-avatar アプリ層（瞬き / 口パク / decorator）
- TLV / multi-byte command
- 暗号化 / 認証
