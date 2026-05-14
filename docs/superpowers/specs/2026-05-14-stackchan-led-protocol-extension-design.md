# 2026-05-14 — stackchan-led + protocol 拡張 設計書

## 1. プロジェクト位置づけ

`2026-05-14-stackchan-protocol-design.md`（顔切替 1-byte protocol）の上位拡張。AI ロボットとしての I/O 完成度を上げるために LED 12 個を扱える状態にし、同時に protocol を 1-byte → frame 形式（picoruby-ot 由来）に置換する。サーボ・BLE・WiFi は本 spec の対象外（後続 sub-project）。

最終形は「Claude Code / cmux 等の AI tool 完了通知が無線で StackChan に届き、表情・LED・サーボでフィードバックされる AI ロボット」。本 spec はその一歩目として **frame protocol 確立 + LED 駆動**だけ動かす。

## 2. ゴール（受け入れ基準）

実機 M5Stack StackChan AI Desktop Robot（CoreS3 ベース）上で以下が動くこと。

1. CoreS3 を USB-C 接続 → R2P2-ESP32 ファームが boot → `/home/app.rb` autostart → 画面に neutral 顔、LED 全消灯
2. macOS から `bundle exec stackchan-control face smile` → 画面が smile に切替、ACK `.` 受信
3. `bundle exec stackchan-control led red breathing` → LED 12 個が赤で 3 秒周期に呼吸、ACK `.` 受信
4. `bundle exec stackchan-control led off` → LED 全消灯
5. `bundle exec stackchan-control combo --face smile --led "green solid"` → 1 frame で顔と LED 同時切替
6. `bundle exec stackchan-control raw "<X:bogus>"` → ACK `?` 受信、CLI exit code 1
7. PC から garbage を投げ込んでも device は復帰し、続く正常 frame は処理される
8. cycling demo は廃止、PC 制御一本

## 3. スコープ

### 3.1 含む

- **(A) 新規 mrbgem `picoruby-py32-io-expander`**：PY32 IO Expander（I2C 0x6F）の low-level driver
- **(B) 新規 mrbgem `picoruby-stackchan-led`**：picoruby-ws2812 風 API + 4 mode animation engine（solid/blink/breathing/off）
- **(C) `picoruby-stackchan-protocol` 改修**：1-byte → frame parser、Dispatcher を F/L 分岐に拡張、cycling demo 廃止
- **(D) PC 側 `pc/stackchan-protocol` 改修**：CLI に `led` / `combo` サブコマンド追加、frame writer
- **(E) R2P2-ESP32 build_config 追加**：新 2 gem を `conf.gem path:` で取り込み
- **(F) 検証手順 doc 拡張**：`docs/STACKCHAN_PROTOCOL_VERIFICATION.md` に LED 確認項目追加

### 3.2 含まない（後続 sub-project）

| 項目 | 想定 spec |
|---|---|
| Servo 駆動（Feetech serial driver + pan/tilt 制御） | P2 spec |
| BLE peripheral（NUS スタイル） | P4 spec |
| WiFi + TCP/HTTP server | P5 spec |
| AI tool 完了通知 → robot reaction の glue（PC 側 Claude Code/cmux 連携） | P6 spec |
| LED per-pixel addressing / rainbow / sweep | v2（最小 4 mode で start） |
| IMU / 頭タッチ / NFC / RTC / マイク・スピーカー | 個別 spec |
| 1-byte protocol との backward compat | 廃止確定（v1 で clean break） |

### 3.3 既存 gem との関係

- `picoruby-ili9342`：変更なし（汎用 LCD driver）
- `picoruby-stackchan-protocol`：拡張のみ。Face::* クラスはそのまま保持
- 新 2 gem は `picoruby-mpu6886` / `picoruby-vl53l0x` のレイアウトを踏襲（pure-Ruby、test/FakeI2C、`mrbgem.rake` で `picoruby-i2c` dependency）

## 4. アーキテクチャ

### 4.1 全体構成

```
┌─────────────────── PC (Mac) ────────────────────────────────────┐
│  Claude Code / cmux / scripts                                    │
│         │                                                         │
│         ▼                                                         │
│  pc/stackchan-protocol/exe/stackchan-control                     │
│  （CLI: face / led / combo / raw）                                 │
│         │                                                         │
│         ▼ frame writer                                            │
│  serial USB-CDC ──────────────→                                   │
└──────────────────────────────────────────────────────────────────┘
                                  │
                                  ▼
┌──────────────────── StackChan AI (CoreS3 + ESP32-S3) ────────────┐
│  /home/app.rb                                                     │
│  ┌──────────────────────────────────────────────────────────┐    │
│  │  Main Loop (50ms tick, non-blocking)                     │    │
│  │   ├─ STDIN.read_nonblock(256) → FrameParser.feed         │    │
│  │   ├─ FrameParser.frames.each → Dispatcher.handle         │    │
│  │   └─ LedAnimator.tick(now_ms)                            │    │
│  └──────────────────────────────────────────────────────────┘    │
│                  │                  │                             │
│   ┌──────────────▼────┐    ┌────────▼─────────┐                  │
│   │ stackchan-protocol│    │ stackchan-led    │                  │
│   │ ・FrameParser     │    │ ・Strip          │                  │
│   │ ・Dispatcher      │    │ ・Animator       │                  │
│   │ ・Face::*         │    │   solid/blink/   │                  │
│   │   (LCD draw)      │    │   breathing/off  │                  │
│   └───────────────────┘    └──────┬───────────┘                  │
│            │                       │                              │
│            ▼                       ▼                              │
│   LCD (SPI ILI9342)         ┌──────────────────┐                 │
│                             │ py32-io-expander │                  │
│                             │ ・LED RAM 0x30   │                 │
│                             │ ・refresh kick   │                 │
│                             │ ・GPIO P0-P15    │                 │
│                             └──────┬───────────┘                  │
│                                    ▼                              │
│                             I2C 0x6F → PY32 → 12 RGB LEDs        │
└──────────────────────────────────────────────────────────────────┘
```

### 4.2 通信媒体

- USB-Serial 一本（USB CDC ACM、`/dev/cu.usbmodem*` on macOS）
- baud 115200（USB CDC は実際無視）
- 後続 P4/P5 で BLE / WiFi に同 protocol を相乗りさせる前提で設計

### 4.3 main loop tick 駆動

50ms tick で:
1. `STDIN.read_nonblock(256)` → 受信があれば parser に feed、frame 取り出して dispatcher に渡す
2. `LedAnimator.tick(now_ms)` で animation の現在 frame を render → I2C で PY32 に書き込み

`Machine.uptime_us` は **main task からのみ呼ぶ**（mruby/c で background Task 内から呼ぶと silent death する。mpu6886 line 301-302 の警告参照）。tick メソッドは `now_ms` を引数で受け取る形にして componentside では呼ばない。

v1 では `picoruby-task` は使わない。Animator は main loop tick 駆動で十分。将来 IMU sampling 等で Task 必要な場合は mpu6886 line 269〜280 の dual-engine pattern（`RUBY_ENGINE == "mruby/c"` で `PicoRubyVM::InstructionSequence.compile().to_binary` → `Task.create`）を踏襲する。

## 5. Components 詳細

### 5.1 `picoruby-py32-io-expander`

**役割**: I2C 0x6F の PY32 chip との low-level talk。LED data RAM、refresh kick、GPIO（v2 以降の servo 電源用）を抽象化。

**ファイル構成**（mpu6886 同型）

```
mrbgem.rake
mrblib/py32_io_expander.rb
test/py32_io_expander_test.rb
README.md
Rakefile
Gemfile
```

**`mrbgem.rake`**

```ruby
MRuby::Gem::Specification.new('picoruby-py32-io-expander') do |spec|
  spec.license = 'MIT'
  spec.author  = 'bash0C7'
  spec.summary = 'PY32 IO Expander driver (M5Stack StackChan base) - pure Ruby PicoRuby Runtime Gem'

  spec.add_dependency 'picoruby-i2c'
  spec.add_test_dependency 'picoruby-picotest'
end
```

**API**

```ruby
class PY32IOExpander
  I2C_ADDRESS = 0x6F
  REG_LED_CFG = 0x24
  REG_LED_RAM_START = 0x30
  REG_LED_COUNT = 0x25  # 推定。実装時に公式 driver で確認

  def initialize(i2c)
    @i2c = i2c
  end

  # LED 系
  def set_led_count(n)
  def write_led_ram(pixels)         # pixels: [[r,g,b], ...] → RGB565 packed
  def refresh_leds                  # REG_LED_CFG bit6 立てて kick

  # GPIO 系（v1 では公開のみ、内部利用なし。servo gem 用に backbone を作っとく）
  def gpio_mode(pin, mode)          # mode: :input / :output / :pull_up / :pull_down
  def gpio_write(pin, value)
  def gpio_read(pin)

  private

  def write_reg(reg, *data)
    result = @i2c.write(I2C_ADDRESS, reg, *data, timeout: 1000)
    raise IOError, "PY32 write failed (reg: 0x#{reg.to_s(16)})" unless result > 0
  end

  def read_reg(reg, length)
    data = @i2c.read(I2C_ADDRESS, length, reg, timeout: 1000)
    raise IOError, "PY32 read failed (reg: 0x#{reg.to_s(16)})" if data.nil? || data.empty?
    data.bytes
  end
end
```

**RGB888 → RGB565 packing**: 公式 driver `PY32IOExpander_Class.cpp` line 338-342 のロジックに合わせる。`r5 = (r >> 3) & 0x1F`, `g6 = (g >> 2) & 0x3F`, `b5 = (b >> 3) & 0x1F`、2 byte big-endian。

### 5.2 `picoruby-stackchan-led`

**役割**: WS2812 風 API + 4 mode animation。device 側 tick で animation 駆動。

**ファイル構成**

```
mrbgem.rake
mrblib/stackchan_led.rb           # Strip 本体
mrblib/stackchan_led/animator.rb  # Animator
test/stackchan_led_test.rb
README.md
Rakefile
Gemfile
```

**`mrbgem.rake`**

```ruby
MRuby::Gem::Specification.new('picoruby-stackchan-led') do |spec|
  spec.license = 'MIT'
  spec.author  = 'bash0C7'
  spec.summary = 'StackChan AI 12-pixel LED driver with animation - pure Ruby PicoRuby Runtime Gem'

  spec.add_dependency 'picoruby-py32-io-expander'
  spec.add_test_dependency 'picoruby-picotest'
end
```

**API**

```ruby
class StackchanLed
  PIXEL_COUNT = 12

  def initialize(py32)
    @py32 = py32
    @py32.set_led_count(PIXEL_COUNT)
    @brightness = 100
    @buffer = Array.new(PIXEL_COUNT) { [0, 0, 0] }
    @animator = Animator.new(self)
    show  # initial blank
  end

  # 静的 API（picoruby-ws2812 風）
  def fill(r, g, b)
    @buffer = Array.new(PIXEL_COUNT) { [r, g, b] }
    self
  end
  def set_rgb(i, r, g, b); @buffer[i] = [r, g, b]; self; end
  def brightness=(v); @brightness = clamp(v, 0, 100); self; end
  def clear; fill(0, 0, 0); end

  def show
    pixels = @buffer.map { |r, g, b| apply_brightness(r, g, b) }
    @py32.write_led_ram(pixels)
    @py32.refresh_leds
    self
  end

  # Animation API
  def animate(r, g, b, mode)        # mode: :solid / :blink / :breathing / :off
    @animator.set(r, g, b, mode)
    self
  end

  # main loop から呼ばれる協調 tick
  def tick(now_ms)
    @animator.tick(now_ms)
  end

  private

  def apply_brightness(r, g, b)
    [r * @brightness / 100, g * @brightness / 100, b * @brightness / 100]
  end

  def clamp(v, lo, hi); v < lo ? lo : (v > hi ? hi : v); end
end
```

**Animator**

```ruby
class StackchanLed::Animator
  # breathing: 12 step LUT、250ms/step = 3 秒周期
  BREATHING_LUT = [0, 5, 20, 45, 70, 90, 100, 90, 70, 45, 20, 5].freeze
  BREATHING_STEP_MS = 250

  # blink: 1Hz（500ms ON / 500ms OFF）
  BLINK_HALF_PERIOD_MS = 500

  def initialize(led)
    @led = led
    @r = @g = @b = 0
    @mode = :off
    @phase_start_ms = nil
  end

  def set(r, g, b, mode)
    @r, @g, @b, @mode = r, g, b, mode
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
      @led.fill(on ? @r : 0, on ? @g : 0, on ? @b : 0).show
    when :breathing
      ratio = BREATHING_LUT[(elapsed / BREATHING_STEP_MS) % BREATHING_LUT.size]
      @led.fill(@r * ratio / 100, @g * ratio / 100, @b * ratio / 100).show
    end
  end

  private

  def dynamic?
    @mode == :blink || @mode == :breathing
  end

  def apply_immediately
    case @mode
    when :solid then @led.fill(@r, @g, @b).show
    when :off   then @led.clear.show
    # :blink, :breathing は次 tick まで何もしない（@phase_start_ms 初期化済み）
    end
  end
end
```

### 5.3 `picoruby-stackchan-protocol` 改修

**変更点**

| 既存 | 改修後 |
|---|---|
| 1-byte parser（`STDIN.read(1)` ブロッキング） | `FrameParser`（`<K:V,K:V>` accumulator）+ `STDIN.read_nonblock(256)` polling |
| Dispatcher が 1 byte → Face class lookup | Dispatcher が frame Hash → key で F/L 分岐 |
| `examples/app.rb` で 4 表情 cycling demo | tick loop（serial poll + LED tick） |
| `Face::*` 4 クラス | 変更なし（保持） |

**FrameParser**

```ruby
class StackchanProtocol::FrameParser
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
```

**Dispatcher**

```ruby
class StackchanProtocol::Dispatcher
  ERROR_BYTE = "?".freeze
  ACK_BYTE = ".".freeze

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

  def initialize(display:, led:)
    @display = display
    @led = led
  end

  def handle(frame)
    attempts = []
    attempts << handle_face(frame) if frame.key?("F")
    attempts << handle_led(frame)  if frame.key?("L")
    success = !attempts.empty? && attempts.all? { |ok| ok }
    write_ack(success)
  rescue => e
    log "dispatch error: #{e.class}: #{e.message}"
    write_ack(false)
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

  def write_ack(success)
    STDOUT.write(success ? ACK_BYTE : ERROR_BYTE)
  end

  def log(msg)
    # 既存 log メカニズムを踏襲
  end
end
```

**examples/app.rb**

```ruby
require 'stackchan_protocol'

# Cold-boot init（既存通り、AXP2101 + AW9523 の生 I2C bytes）
# ... 省略 ...

# Peripheral setup
i2c = I2C.new(...)
py32 = PY32IOExpander.new(i2c)
led = StackchanLed.new(py32)
display = ILI9342.new(...)

# Protocol setup
parser = StackchanProtocol::FrameParser.new
dispatcher = StackchanProtocol::Dispatcher.new(display: display, led: led)

# Initial state
StackchanProtocol::Face::Neutral.new.draw(display)

# Main loop
TICK_MS = 50
loop do
  tick_start_ms = Machine.uptime_us / 1000
  if (chunk = STDIN.read_nonblock(256))
    parser.feed(chunk).each { |f| dispatcher.handle(f) }
  end
  led.tick(tick_start_ms)
  elapsed = (Machine.uptime_us / 1000) - tick_start_ms
  remaining = TICK_MS - elapsed
  sleep_ms(remaining) if remaining > 0
end
```

### 5.4 PC 側 `pc/stackchan-protocol`

**CLI 変更**

```bash
# Face（既存維持、内部で frame に変換）
stackchan-control face neutral|smile|joy|surprised

# LED 新規
stackchan-control led <color> [<mode>]
#   <color>: red / green / blue / yellow / cyan / magenta / white / off
#            または "rgb(R,G,B)" 形式
#   <mode>:  solid (default) / blink / breathing / off

# 複合（1 frame で送る）
stackchan-control combo --face <name> --led "<color> <mode>"

# 生 frame
stackchan-control raw "<F:1,L:R:0,G:255,B:0,M:s>"
```

**新規ファイル**

- `lib/stackchan_protocol/frame_writer.rb`：Hash → `<K:V,K:V>` 文字列化
- `lib/stackchan_protocol/led_color_table.rb`：name → `[r,g,b]`
- `lib/stackchan_protocol/cli/led_command.rb`：`led` サブコマンド
- `lib/stackchan_protocol/cli/combo_command.rb`：`combo` サブコマンド

`face_table.rb` は frame index の `"0"`〜`"3"` mapping に簡略化（1 byte 直送のための constants は廃止）。

`Client#set_face(name)` は frame writer 経由 `<F:N>` を送る形に書き換え。`Client#set_led(r, g, b, mode)` 新規。

### 5.5 R2P2-ESP32 build_config

`bash0C7/R2P2-ESP32/build_config/xtensa-esp-picoruby.rb` に追記:

```ruby
conf.gem path: "#{ENV['STACKCHAN_PICORUBY_ROOT']}/mrbgems/picoruby-py32-io-expander"
conf.gem path: "#{ENV['STACKCHAN_PICORUBY_ROOT']}/mrbgems/picoruby-stackchan-led"
# 既存 picoruby-stackchan-protocol は変更なし
```

`STACKCHAN_PICORUBY_ROOT` env var は既存 setup で設定済みのはず（要確認）。

## 6. Wire Format Spec

### 6.1 Frame 構造

```
< KEY : VAL [, KEY : VAL]* > [\n]
```

- 開始: `<`、終了: `>`、`\n` は parser には不要（trailing として無視）
- ペア区切り: `,`、key:value 区切り: `:`
- ASCII 印字可能のみ
- 最大 frame サイズ: 64 bytes（buffer 4096 内で複数 frame 可）
- 大文字小文字区別あり（key）

### 6.2 Command 表

| Frame | 意味 | ACK |
|---|---|---|
| `<F:0>` `<F:1>` `<F:2>` `<F:3>` | Face Neutral / Smile / Joy / Surprised | `.` |
| `<L:1,R:0,G:255,B:0,M:s>` | LED 緑 solid | `.` |
| `<L:1,R:255,G:255,B:0,M:p>` | LED 黄 breathing | `.` |
| `<L:1,R:255,G:0,B:0,M:b>` | LED 赤 blink | `.` |
| `<L:1,M:o>` | LED off（RGB 省略可） | `.` |
| 複合: `<F:1,L:1,R:0,G:255,B:0,M:s>` | smile + LED 緑 solid 同時 | `.` |
| Unknown key / invalid value / partial | — | `?`（partial は ACK なし） |

### 6.3 Key 仕様

| Key | 意味 | Value 形式 |
|---|---|---|
| `F` | Face index | `0`〜`3`（FACE_TABLE） |
| `L` | LED block marker | `1` 固定（後続 R/G/B/M が LED 用と示す） |
| `R` `G` `B` | LED 色 | integer 0〜255 |
| `M` | LED mode | `s`/`b`/`p`/`o` |

**`B` key の衝突回避**: `B` は LED block 内でのみ青成分扱い。Brightness は v1 で protocol 外（API のみ）。v2 で必要なら別 key（例: `Y` for brightness）を割り当てる。

### 6.4 Data Flow

```
[PC] stackchan-control led red breathing
      ↓ build frame
      "<L:1,R:255,G:0,B:0,M:p>\n"
      ↓ USB-CDC write
[Device main loop tick]
      STDIN.read_nonblock(256) → "<L:1,R:255,G:0,B:0,M:p>\n"
      ↓
      FrameParser.feed → [{ "L"=>"1", "R"=>"255", "G"=>"0", "B"=>"0", "M"=>"p" }]
      ↓
      Dispatcher.handle
      ↓ handle_led
      StackchanLed#animate(255, 0, 0, :breathing)
      ↓ Animator state 更新
      STDOUT.write(".")  # ACK
      ↓ 次 tick で
      LedAnimator#tick(now_ms)
      ↓
      StackchanLed#fill(...).show
      ↓
      PY32IOExpander#write_led_ram(pixels) + refresh_leds
      ↓ I2C 0x6F
      PY32 → 12 LEDs 点灯
```

## 7. Error Handling

### 7.1 Device 側

| 失敗箇所 | 動作 | ACK |
|---|---|---|
| Frame parse 失敗（partial / 空 frame） | `parse_error_count += 1`、buffer 部分破棄継続 | なし |
| Frame 完成したが key 不明 / value 不正 | Dispatcher が `?` ACK | `?` |
| Face class lookup miss | `?` ACK | `?` |
| LED mode 不明 | `?` ACK | `?` |
| `StackchanLed` 内 IOError（PY32 write 失敗） | Dispatcher rescue、log + `?` ACK | `?` |
| その他 device 例外 | Dispatcher rescue、log + `?` ACK | `?` |

**Buffer overflow**: `MAX_BUFFER = 4096` 超過したら **古い側を破棄**。frame 64 bytes 想定なので余裕。

**No silent rescue**（CLAUDE.md ルール）: 全 rescue は log するか re-raise。`rescue nil` 禁止。

### 7.2 PC 側

- ACK 待ちタイムアウト: 200ms
- ACK が `?` → CLI exit code 1、stderr に frame と reason
- ACK 未到達 → exit code 2、stderr「device unresponsive」

## 8. Testing Strategy

### 8.1 Unit tests（CRuby host）

| gem | test 対象 | mock |
|---|---|---|
| `picoruby-py32-io-expander` | write_led_ram の I2C 書き込み順序、refresh の REG bit 操作、IOError raise 条件 | FakeI2C（mpu6886 同型: `writes` 配列、`queue_read`） |
| `picoruby-stackchan-led` | fill/set_rgb/clear/brightness の buffer 状態、Animator tick 0/250/500/750/1000ms の出力 | FakePY32（`write_led_ram_calls`、`refresh_count` 記録） |
| `picoruby-stackchan-protocol` | FrameParser の分割 chunk、garbage tolerance、複数 frame in 1 chunk、Dispatcher の F/L 分岐、ACK byte | FakeDisplay（既存）+ FakeLed（`animate_calls` 記録） |

**FakeI2C 例**（mpu6886 line 28-51 同型）

```ruby
class FakeI2C
  attr_reader :writes
  def initialize; @writes = []; @read_queue = []; end
  def queue_read(bytes); @read_queue << bytes; end
  def write(addr, *args, **opts)
    @writes << { addr: addr, args: args, opts: opts }
    args.flatten.size
  end
  def read(addr, length, reg = nil, **opts)
    @read_queue.shift || ("\x00".b * length)
  end
end
```

### 8.2 Integration test（host）

```ruby
def test_combined_face_and_led_frame
  led = FakeLed.new
  display = FakeDisplay.new
  parser = FrameParser.new
  dispatcher = Dispatcher.new(display: display, led: led)

  parser.feed("<F:1,L:1,R:0,G:255,B:0,M:s>\n").each { |f| dispatcher.handle(f) }

  assert_equal Face::Smile, display.last_face_class
  assert_equal [0, 255, 0, :solid], led.last_animate_args
end
```

### 8.3 Hardware verification（実機）

`docs/STACKCHAN_PROTOCOL_VERIFICATION.md` を拡張、以下追加:

1. **Cold-boot**: CoreS3 reset → 全 LED 消灯（initial blank）
2. **Solid color 全色**: 赤/緑/青/白/黄/シアン/マゼンタが均一発光
3. **Animation**: blink 1Hz 確認、breathing が滑らかに 3s 周期で増減
4. **Mode 切り替え**: solid → breathing → off の遷移即時反映
5. **Brightness API**: `led.brightness = 50` で輝度半分
6. **Face + LED 複合 frame**: 表情と LED が同時切替
7. **Garbage tolerance**: `garbage<F:1>more garbage<L:1,M:o>` で 2 frame 通る
8. **Buffer overflow recovery**: 8KB の garbage 投入後も次の正常 frame で復帰
9. **PC CLI**: `stackchan-control led red breathing` がスムーズに反映、ACK 受信

### 8.4 何を test しないか（YAGNI 明示）

- Float/sin の精度比較（LUT 方式やから対象外）
- 1ms 未満のタイミング精度（cooperative loop なので元々無理）
- 複数同時接続（single USB-CDC 前提）
- Servo / BLE / WiFi（別 sub-project）

## 9. Migration / Backward Compat

**Backward compat なし**（user 決定）。

- 1-byte protocol（`'0'`〜`'3'`）は完全廃止
- 旧 `Client#set_face(:smile)` シグネチャ自体は維持、内部実装を frame writer に書き換え
- 旧 `cycling demo` 廃止（`examples/app.rb` から削除）
- 既存 hardware verification doc の 1-byte 関連項目は frame 形式に書き換え

## 10. Open Questions / 後続 spec

- **PY32 register map の完全把握**: REG_LED_CFG bit6 = refresh トリガは確認済みだが、LED count 設定 register、GPIO mode register 番地は実装時に公式 driver 再確認要
- **Animation 拡張（v2）**: rainbow / sweep / per-pixel 必要になったら別 spec
- **Servo 駆動（P2）**: Feetech serial 1Mbaud、UART1 GPIO 6/7、ID 1=pan / ID 2=tilt、PY32 P0 で電源 ON
- **BLE bridge（P4）**: `picoruby-ble-uart` を build に追加、frame をそのまま BLE characteristic に流す
- **WiFi bridge（P5）**: `picoruby-network` + `picoruby-socket`、TCP server で frame 受信
- **AI tool 完了通知 → robot reaction（P6）**: Claude Code hook + cmux integration、PC 側 client 拡張

## 11. References

- `docs/superpowers/specs/2026-05-14-stackchan-protocol-design.md` — 前 spec（1-byte 版）
- `docs/superpowers/specs/2026-05-10-stackchan-display-bringup-design.md` — display bringup
- `docs/superpowers/handoff-2026-05-14-stackchan-display.md` — 直前セッション handoff
- `/Users/bash/dev/src/github.com/bash0C7/picoruby-mpu6886` — I2C gem 先行実装（mrbgem 構成 / FakeI2C / Task pattern）
- `/Users/bash/dev/src/github.com/bash0C7/picoruby-vl53l0x` — 同上
- `/Users/bash/dev/src/github.com/bash0C7/picoruby-ot` — picoruby-ot 通信パターン（FrameParser 由来）
- `https://github.com/ksbmyk/picoruby-ws2812` — WS2812 gem（API 表面 inspiration）
- `/Users/bash/dev/src/github.com/m5stack/StackChan/firmware/main/hal/drivers/PY32IOExpander_Class/PY32IOExpander_Class.cpp` — 公式 PY32 driver（register / bit 仕様の authoritative source）
- `/Users/bash/dev/src/github.com/m5stack/StackChan/firmware/main/hal/hal_io_expander.cpp` — 公式 board init
- `/Users/bash/dev/src/github.com/picoruby/picoruby/mrbgems/picoruby-task-ext/` — Task gem（v2 で利用候補）
- `/Users/bash/dev/src/github.com/picoruby/picoruby/mrbgems/picoruby-pio/example/sk6812.rb` — animation main loop pattern
- `/Users/bash/dev/src/github.com/picoruby/picoruby/mrbgems/picoruby-psg/mrblib/keyboard.rb` — STDIN.read_nonblock pattern
- `CLAUDE.md` — repo ルール（ﾛﾝｸﾞﾊﾞｯﾁ / no silent rescue / driver gem 構成 / 公式 firmware 不可侵）
