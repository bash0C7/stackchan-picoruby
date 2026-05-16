# BLE Phase 3 — `stackchan-ble-client` Control SDK + Device `application.rb` Dispatcher (2026-05-17)

## 1. Context / Phase positioning

Phase 2 (Mac autonomous BLE verification loop + NUS bring-up) は完了済み。`rake r2p2:ble_verify` で device 側 `ble_smoke.rb` に対して 9 phase 直列 PASS を取れる状態にある。両 PR (stackchan-picoruby#1, rb-corebluetooth-mac#1) は 2026-05-16 に squash-merge 済み。

Phase 3 は **BLE 経由で表情と LED を制御してスタックちゃんとして名乗れる** 最初の sub-phase。元の handoff (`docs/superpowers/specs/2026-05-16-ble-phase3-handoff.md`) のオプション **A (Mac BLE control CLI 本実装) + D (device 側 production dispatcher)** を同時実施する位置取り。

サーボ (オプション B 前提) は **Phase 3.5 として分離**。Mac CoreBluetooth + Web Bluetooth bridge (C) も同様に保留。Phase 4 (AI bridge) は A+D が先。

### 1.1 Phase 3 で必ず動く状態 (goal)

```bash
bash0C7@mac $ cd ~/dev/src/github.com/bash0C7/stackchan-picoruby
bash0C7@mac $ rake r2p2:ble_control_smoke COLOR=red MODE=blink FACE=joy
[smoke] upload application.mrb / reset / wait autostart
[smoke] running stackchan-ble-control combo --face joy --led 'red blink'
[smoke] PASS — face=joy LED=red blink (both sides) — visual check please
$ echo $?
0
```

このコマンドが exit 0 で帰り、CoreS3 の LCD に joy 顔・LED ring が red blink している状態を確認できれば Phase 3 達成。

## 2. Scope decisions

| # | 決定 | 補足 |
|---|---|---|
| 1 | サーボ (pan/tilt) は **Phase 3.5 へ分離** | `picoruby-scservo` gem 新規 + UART driver + protocol 拡張は別 session |
| 2 | LED 左右分離は **Phase 3 で全部実装** | `:left` / `:right` / `:both` 3 値、ハード 12 pixel ring を index 切りで実現 |
| 3 | LED 色指定は 4 形式すべて実装 | named / RGB hex / HSB hex / mode キーワード引数 |
| 4 | DSL は `client.send do |stackchan| ... end` block 形式 | block 内 `(method, side)` ごとに最後勝ち集約、frame 配列に encode |
| 5 | Mac 新規 gem `pc/stackchan-ble-client/` 独立 gem 構成 | 高レベル API + example CLI 同梱 |
| 6 | 既存 `pc/stackchan-protocol/` gem は **完全廃止** | USB-serial 通信機能と `stackchan-ble-verify` exe は削除、`frame_writer`/table は新 gem stackchan-ble-client に統合。`picomodem-upload` は deploy script として Rakefile 側 (`lib/deploy/picomodem.rb`) に統合 |
| 7 | device 新規ファイルは `application.rb` (mrbc → `app.mrb`) | `mrbgems/picoruby-stackchan-protocol/examples/application.rb`、`r2p2:upload_mrb SRC=...` で `/home/app.mrb` に転送 |
| 8 | device 起動時間は **無限 advertise** | `peri.start(0)` (BTstack run_loop が永続)。先頭で **5 秒の escape hatch** (crash loop からの shell 復帰窓) |
| 9 | face/LED は 1 frame combine しない | Phase 3 では face frame と LED frame を分離送信、block セマンティクスを直線的に保つ。旧 `combo` 仕様は廃止 |
| 10 | WebSocket / Web Bluetooth (handoff C) は今 session 外 | 長期 follow-up |

## 3. Architecture

```
┌─────────────────────────────┐         BLE NUS         ┌──────────────────────────────────┐
│ Mac stackchan-ble-client    │  ←──── notify (ACK) ────│ CoreS3 application.rb (app.mrb)   │
│   ├ Client (high-level API) │  ─── write_w/o_resp ──→ │   ├ cold-boot init                 │
│   ├ Block DSL (#send)        │      <F:..>\n等          │   ├ 5s escape hatch                │
│   ├ Frame encoder            │                          │   ├ BLE peripheral (NUS)           │
│   └ corebluetooth_mac        │                          │   ├ FrameParser ──→ Dispatcher    │
│ exe/stackchan-ble-control    │                          │   └ AckSink → NUS TX notify       │
│ (Mac CLI 唯一の entry point)  │                          │ application.rb は無限 advertise    │
└─────────────────────────────┘                          └──────────────────────────────────┘
```

## 4. Mac side — `pc/stackchan-ble-client/` gem

### 4.1 File layout (新規)

```
pc/stackchan-ble-client/
├── lib/stackchan_ble_client/
│   ├── client.rb              # 高レベル API (connect/send/disconnect)
│   ├── send_builder.rb        # DSL block の receiver / aggregator
│   ├── frame_codec.rb         # encode (ASCII frame) + ACK decode
│   ├── face_table.rb          # FACE_INDICES = {neutral:0, smile:1, joy:2, surprised:3}
│   ├── led_color_table.rb     # LED_COLORS / LED_MODES
│   ├── hsb_to_rgb.rb          # HSB packed → RGB packed
│   └── version.rb
├── exe/
│   └── stackchan-ble-control  # optparse + sub-command (唯一の Mac CLI)
├── test/
│   ├── frame_codec_test.rb
│   ├── send_builder_test.rb
│   ├── hsb_to_rgb_test.rb
│   ├── client_test.rb         # fake transport
│   └── test_helper.rb
├── stackchan_ble_client.gemspec
├── Gemfile                    # corebluetooth_mac (path:local), test-unit
├── Rakefile                   # rake test
└── README.md
```

### 4.2 高レベル API

```ruby
require 'stackchan_ble_client'

client = StackchanBleClient::Client.new(
  device_name: ENV.fetch('BLE_DEVICE_NAME', 'StackChan-PicoRuby'),
  scan_timeout: Float(ENV.fetch('BLE_SCAN_TIMEOUT', '10')),
  ack_timeout:  Float(ENV.fetch('BLE_ACK_TIMEOUT', '3')),
)
client.connect       # scan + connect + discover services + subscribe NUS TX

client.send do |stackchan|
  stackchan.face(:joy)
  stackchan.led(:red)
  stackchan.led(:rgb, 0xFF8000, mode: :blink)
  stackchan.led(:hsb, 0x80FFFF, side: :left)
  stackchan.led(:blue, side: :right, mode: :breathing)
end
# block を抜けると集約 frame 配列を順に NUS RX に write、各 ACK を NUS TX notify から待つ

client.disconnect
```

### 4.3 Block DSL semantics

`SendBuilder` (block 内 `stackchan` receiver) は以下を提供:

```ruby
class SendBuilder
  def face(name)
  def led(form, value = nil, side: :both, mode: :solid)
end
```

* `face(name)` — `:neutral` / `:smile` / `:joy` / `:surprised`
* `led(form, value, side:, mode:)`:
  * `form == named symbol` (`:red`/`:green`/...) → `LED_COLORS` 引いて RGB へ。`value` は無視 (`nil` 可)
  * `form == :rgb` → `value` は 24-bit packed (0xRRGGBB)
  * `form == :hsb` → `value` は 24-bit packed (0xHHSSBB)、`HsbToRgb#convert` で RGB に変換
  * `side` ∈ `[:left, :right, :both]` (default `:both`)
  * `mode` ∈ `[:solid, :blink, :breathing, :off]` (default `:solid`)

**集約規則**:

| ルール | 動作 |
|---|---|
| 重複呼出の判定キー | `face` は 1 key、`led` は `(side)` で 3 key (`:left` / `:right` / `:both`) |
| 重複時 | **最後勝ち** (block 内で同 key の後の呼出が前を上書き) |
| 送信順 | 同 key の最後勝ち版が、その key の **最初に出現した位置** の順序で並ぶ (= block の自然な記述順を保持) |
| 集約結果 | 最大 4 frame: face / led both / led left / led right |
| ACK 期待 | frame ごとに 1 byte (`.` = OK / `?` = device error)、`client.send` は全部 `.` なら成功 return、1 個でも `?` なら `StackchanBleClient::DeviceError` raise |

**例**: 上の DSL コードは:

1. `stackchan.face(:joy)` → face 集約 = `:joy`
2. `stackchan.led(:red)` → led `:both` 集約 = (red, solid)
3. `stackchan.led(:rgb, 0xFF8000, mode: :blink)` → led `:both` 上書き = (0xFF8000, blink)
4. `stackchan.led(:hsb, 0x80FFFF, side: :left)` → led `:left` 集約 = (hsb→rgb, solid)
5. `stackchan.led(:blue, side: :right, mode: :breathing)` → led `:right` 集約 = (blue, breathing)

送信される frame (順):

```
<F:2,M:s>\n                       # face joy
<L:1,R:255,G:128,B:0,S:B,M:b>\n   # led both, 0xFF8000, blink
<L:1,R:128,G:255,B:255,S:L,M:s>\n # led left, HSB 0x80FFFF → RGB, solid
<L:1,R:0,G:0,B:255,S:R,M:p>\n     # led right, blue, breathing
```

### 4.4 Color forms 詳細

#### Named color

`LED_COLORS = { red: [255,0,0], green: [0,255,0], blue: [0,0,255], yellow: [255,255,0], white: [255,255,255], off: [0,0,0] }` (現 stackchan-protocol テーブル移植、必要なら拡張)

#### RGB packed `0xRRGGBB`

```
0xFF8000 → R=0xFF, G=0x80, B=0x00
```

#### HSB packed `0xHHSSBB`

```
0xHHSSBB
  HH: hue        0-255  → 0-360° linear (256 step circular)
  SS: saturation 0-255  → 0-100% linear
  BB: brightness 0-255  → 0-100% linear (= HSV value)
```

`HsbToRgb#convert(packed) → [r, g, b]`。アルゴリズムは standard HSV→RGB (Wikipedia の HSV to RGB)。device 側は RGB しか知らない (firmware 軽量化)。

#### Mode

| Symbol | Frame char | Animator 挙動 |
|---|---|---|
| `:solid` | `s` | 即時表示 |
| `:blink` | `b` | 1Hz on/off (500ms each) |
| `:breathing` | `p` | 3 秒サイクル、12-step intensity LUT |
| `:off` | `o` | 即時 off |

### 4.5 Exe: `stackchan-ble-control`

USB-serial 版 `stackchan-control` と同形の optparse + sub-command。**ただし transport は BLE 固定**、内部で `StackchanBleClient::Client` を使う。

```bash
bundle exec stackchan-ble-control face joy
bundle exec stackchan-ble-control led red blink                # both
bundle exec stackchan-ble-control led red blink --side left
bundle exec stackchan-ble-control led-rgb 0xFF8000 --mode blink
bundle exec stackchan-ble-control led-hsb 0x80FFFF --side left
bundle exec stackchan-ble-control combo --face joy --led 'red blink'
bundle exec stackchan-ble-control raw '<X:1>\n'
```

`combo` は internal で 1 回の `client.send` block に face と led を入れて発射するだけ。1 frame combine ではなく 2 frame 連射。

Exit code scheme:

| code | 意味 |
|---|---|
| 0 | PASS |
| 2 | adapter (CoreBluetooth state error) |
| 3 | timeout |
| 4 | connection (lost / refused) |
| 5 | assertion (unknown face name 等、ACK `?`) |
| 9 | uncategorized |

### 4.6 ~~Exe: `stackchan-ble-verify`~~ (削除)

Phase 2 の `pc/stackchan-protocol/exe/stackchan-ble-verify` は **削除**。ble_control_smoke が同等の BLE 経路 (scan/connect/discover/write/notify) を control DSL 経由で全部踏むため redundant。Mac 側 E2E entry point は `stackchan-ble-control` 1 本に統一する。

## 5. Device side — `application.rb` + Dispatcher 拡張

### 5.1 File layout (新規/変更)

```
mrbgems/picoruby-stackchan-protocol/
├── examples/
│   ├── app.rb                 # 既存 bring-up smoke (LED/LCD cold-boot 検証用、別ファイルとして残す)
│   └── application.rb         # 新規 production dispatcher (BLE + Dispatcher)
│   # ble_smoke.rb は削除 (application.rb に subsumed)
└── mrblib/stackchan_protocol/
    ├── frame_parser.rb        # 既存 (変更なし)
    └── dispatcher.rb          # S key 対応で拡張

mrbgems/picoruby-stackchan-led/mrblib/
├── stackchan_led.rb           # fill_range / fill_left / fill_right 追加
└── stackchan_led/animator.rb  # side-aware (left/right 独立 Animator)
```

### 5.2 `application.rb` 構造

```ruby
# examples/application.rb

require 'spi'
require 'gpio'
require 'i2c'
require 'machine'
require 'ili9342'
require 'py32-io-expander'
require 'stackchan-led'
require 'stackchan-protocol'
require 'ble'

# [1] 5-second escape hatch (crash loop からの脱出窓)
sleep_ms 5000

# [2] cold-boot init (app.rb と同一手順)
#     AXP2101 PMIC → AW9523 IO expander → ILI9342 LCD → PY32 IO expander
#     → StackchanLed init (12 LED ring, 内部 blank) → Face::Neutral 描画
# ... (現 app.rb の init ブロックをそのまま移植) ...

# [3] BLE NUS service 構築 + Dispatcher 結線
#     NUS UUID / property mask / GATT DB 構築は Phase 2 ble_smoke.rb から
#     コピー移植 (元ファイルは Phase 3 で削除)
class StackChanApp < BLE

  def initialize(display:, led:)
    @display = display
    @led     = led
    @parser  = StackchanProtocol::FrameParser.new
    @ack_sink = AckSink.new(self)
    @dispatcher = StackchanProtocol::Dispatcher.new(
      display: @display, led: @led, stdout: @ack_sink
    )
    # ... NUS GATT DB 構築、handle 取得 ...
    super(:peripheral, db.profile_data)
  end

  def heartbeat_callback
    # NUS RX を drain → FrameParser に feed → frame ごとに Dispatcher#handle
    while (rx_data = pop_write_value(@rx_handle))
      @parser.feed(rx_data).each do |frame|
        @dispatcher.handle(frame)  # ACK byte は @ack_sink.write 経由で queue
      end
    end
    # CCCD subscribe 状態の更新
    cccd = pop_write_value(@tx_cccd_handle)
    @notify_enabled = (cccd == "\x01\x00") if cccd
    # AckSink の queue を排出
    @ack_sink.flush_if_subscribed(@notify_enabled)
    # LED animator の tick
    @led.tick(Machine.uptime_us / 1000)
  end

  def packet_callback(event_packet)
    # state working → advertise / disconnect → notify reset / can_send_now → notify(@tx_handle)
    # (Phase 2 ble_smoke.rb と同じパターンを application.rb に取り込む)
  end
end

# AckSink: Dispatcher の @stdout interface (write(byte)) を実装、
# 内部 queue に積み、heartbeat_callback で can_send_now を要求して
# NUS TX 経由で notify 送出する
class AckSink
  def initialize(ble)
    @ble = ble
    @queue = String.new
  end

  def write(byte)
    @queue << byte
  end

  def flush_if_subscribed(subscribed)
    return unless subscribed
    return if @queue.empty?
    byte = @queue[0]
    @queue = @queue[1, @queue.bytesize - 1] || String.new
    @ble.push_tx(byte)  # → push_read_value + request_can_send_now_event
  end
end

# [4] 無限 advertise + dispatcher loop
peri = StackChanApp.new(display: display, led: led)
peri.debug = true
peri.start(0)   # peri.start(0) は BTstack run_loop が永続。crash 時は escape hatch まで戻る
```

#### 5.2.1 escape hatch の意図

`sleep_ms 5000` の 5 秒間は **何も BLE/I2C を触らない**。これにより:

- crash loop が起きていてもこの 5 秒の間に shell が STDIN を受け付け、人間が monitor で `rm /home/app.mrb` できる
- `r2p2:upload_mrb` 直後の boot で uploader と autostart の race も escape hatch 内に余裕で収まる
- Phase 2 ble_smoke.rb の 2 秒では境界事象でカツカツだったので 5 秒に延長

### 5.3 Dispatcher 拡張 (`mrblib/stackchan_protocol/dispatcher.rb`)

現状の `Dispatcher#handle_led` は `S` key を見ない (= 全 LED 同色)。本 spec で以下を追加:

```ruby
SIDE_TABLE = {
  "L" => :left,
  "R" => :right,
  "B" => :both,
}.freeze

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

`S` key 必須 (省略 / 未知値はどちらも `?` ACK)。Mac 側 SDK は必ず `S` を載せる。

### 5.4 LED driver 拡張 (`picoruby-stackchan-led`)

```ruby
class StackchanLed
  PIXEL_COUNT  = 12
  # left/right の物理 index 分割: 0-5=left, 6-11=right (draft assumption)
  # 実機目視確認後に必要なら fine-tune。最終決定は spec の後の plan execution で。
  LEFT_RANGE  = (0..5)
  RIGHT_RANGE = (6..11)

  # 既存メソッド (fill / set_rgb / brightness= / clear / show) はそのまま

  def fill_range(start_idx, end_idx, r, g, b)
    (start_idx..end_idx).each { |i| @buffer[i] = [r, g, b] }
    self
  end

  def fill_left(r, g, b)
    fill_range(LEFT_RANGE.first, LEFT_RANGE.last, r, g, b)
  end

  def fill_right(r, g, b)
    fill_range(RIGHT_RANGE.first, RIGHT_RANGE.last, r, g, b)
  end

  def animate_side(side, r, g, b, mode)
    case side
    when :both
      left_animator.set(r, g, b, mode)
      right_animator.set(r, g, b, mode)
    when :left
      left_animator.set(r, g, b, mode)
    when :right
      right_animator.set(r, g, b, mode)
    end
    self
  end

  def tick(now_ms)
    left_animator.tick(now_ms)
    right_animator.tick(now_ms)
  end

  private

  def left_animator
    @left_animator ||= Animator.new(self, side: :left)
  end

  def right_animator
    @right_animator ||= Animator.new(self, side: :right)
  end
end
```

`Animator` も side-aware に refactor:

```ruby
class Animator
  def initialize(led, side: :both)
    @led  = led
    @side = side
    # ... 残り変更なし、ただし apply_color の代わりに side ごとの fill メソッドを呼ぶ
  end

  private

  def apply_color(r, g, b)
    case @side
    when :both  then @led.fill(r, g, b).show
    when :left  then @led.fill_left(r, g, b);  @led.show
    when :right then @led.fill_right(r, g, b); @led.show
    end
  end
end
```

`apply_color` の細部は実装時に最適化 (`show` を 1 回に集約する etc)。

旧 `StackchanLed#animate(r, g, b, mode)` (side 引数なし) は **削除**。呼び側 (既存 Dispatcher / test) も `animate_side(:both, ...)` を直接呼ぶ形に更新する。

#### 5.4.1 left/right index 分割の物理確認 (open)

12 LED ring の物理 index 配置 (0 番がどこか、回転方向) は実機目視で確認するまで仮定。仮 `0-5 = left / 6-11 = right` で実装、Phase 3 plan の verification step で「left を red、right を blue にして目視して半分ずつ正しく光っているか」を確認、必要なら index を入れ替え or rotate。

## 6. Frame protocol on BLE

### 6.1 Frame format (拡張後)

```
<key:value,key:value,...>\n
```

| Key | 意味 | 値 |
|---|---|---|
| `F` | face index | `0`-`3` (`FACE_TABLE`) |
| `L` | LED 操作 marker | `1` のみ。`L` が存在 = LED frame |
| `R` `G` `B` | RGB | `0`-`255` 各々 |
| `S` | LED side | `L` / `R` / `B` (LED frame で必須) |
| `M` | mode | `s` (solid) / `b` (blink) / `p` (breathing) / `o` (off)、LED frame で必須 |

未知 key は parser がそのまま hash に格納するが、Dispatcher は読まない (= 副作用なし、エラーにもならない)。必須 key 不足 / 未知 enum 値は `?` ACK。`L` か `F` のどちらかが必須 (両方含む frame は本仕様では送らない、§4.3 集約の通り)。

### 6.2 NUS mapping

| 方向 | Channel | 形式 | 同期 |
|---|---|---|---|
| Mac → Device | NUS RX (Write Without Response) | ASCII frame | fire-and-forget write |
| Device → Mac | NUS TX (Notify) | 1 byte ACK (`.` / `?`) per frame | Mac は subscribe 後 ack_timeout 内待ち |

ATT MTU 182B 想定、frame は 50B 以下なので分割不要。

### 6.3 ACK セマンティクス

| Frame に対する device 動作 | TX notify byte |
|---|---|
| 全 handler 成功 | `.` (0x2E) |
| いずれかの handler が `false` 返却 | `?` (0x3F) |
| parser/handler が例外 | `?` |
| 必須 key 不足 / 不正 enum 値 | `?` |

Mac 側 `Client#send` は frame 配列を順に発射し、各 frame の ACK を `ack_timeout` 内に受信できなければ `StackchanBleClient::TimeoutError`、`?` を受けたら `StackchanBleClient::DeviceError` raise。

## 7. `pc/stackchan-protocol/` gem 廃止 + Rakefile 再編

### 7.1 削除対象

```
pc/stackchan-protocol/                       # gem 全体を削除
  ├── lib/stackchan_protocol/cli.rb
  ├── lib/stackchan_protocol/client.rb
  ├── lib/stackchan_protocol/frame_writer.rb # → stackchan-ble-client/lib/.../frame_codec.rb へ移転
  ├── lib/stackchan_protocol/face_table.rb   # → stackchan-ble-client/lib/.../face_table.rb へ移転
  ├── lib/stackchan_protocol/led_color_table.rb  # 同上
  ├── exe/stackchan-control                  # 削除
  ├── exe/stackchan-ble-verify               # 削除 (ble_control_smoke に subsumed、§4.6)
  ├── exe/picomodem-upload                   # → lib/deploy/picomodem.rb (project root 下) へ移植
  └── ... (Gemfile / Rakefile / test 全部)
```

### 7.2 `lib/deploy/picomodem.rb` への移植

`pc/stackchan-protocol/exe/picomodem-upload` の Ruby + uart logic を独立 module として project root 直下に置く:

```
lib/deploy/picomodem.rb
```

API:

```ruby
require_relative '../lib/deploy/picomodem'

Deploy::Picomodem.upload(src: '/abs/path/to/file', dst: '/home/app.mrb', port: '/dev/cu.usbmodemXXX')
# 内部で STX / file_ack handshake を実行、成功 false で例外 raise
```

`Rakefile` の `r2p2:upload` / `r2p2:upload_mrb` はこれを require して直接呼ぶ:

```ruby
task :upload_mrb do
  # ... picorbc compile (既存) ...
  require_relative 'lib/deploy/picomodem'
  Deploy::Picomodem.upload(src: mrb_path, dst: '/home/app.mrb', port: port)
end
```

### 7.3 Rakefile 編集サマリ

| Task | 変更 |
|---|---|
| `r2p2:upload` | `bundle exec exe/picomodem-upload` 呼出を `Deploy::Picomodem.upload(...)` 呼出に置換 |
| `r2p2:upload_mrb` | 同上 |
| `r2p2:send_led` | **削除** (USB-serial CLI 廃止) |
| `r2p2:send_face` | **削除** (同上) |
| `r2p2:verify_led` | **削除** (`send_led` 依存) |
| `r2p2:ble_verify` | **削除** (ble_control_smoke に subsumed) |
| `r2p2:ble_control_smoke` | **新規追加** (下記 §8) |

## 8. E2E smoke — `rake r2p2:ble_control_smoke`

### 8.1 動作契約

```bash
rake r2p2:ble_control_smoke [COLOR=red] [MODE=blink] [FACE=joy] [SIDE=both]
```

| ENV | default | 意味 |
|---|---|---|
| `COLOR` | `red` | LED 色 (named) |
| `MODE` | `solid` | LED mode |
| `FACE` | `neutral` | face name |
| `SIDE` | `both` | LED side |
| `AUTOSTART_WAIT` | `12` | reset 後の autostart + 5s escape + BLE init 待ち時間 (秒) |

内部動作 (sequential):

1. `r2p2:upload_mrb SRC=mrbgems/picoruby-stackchan-protocol/examples/application.rb` — host picorbc + Deploy::Picomodem で `/home/app.mrb` 上書き
2. `r2p2:reset` — RTS pulse
3. `sleep AUTOSTART_WAIT` — autostart + 5s escape + BLE init + advertise 開始まで
4. `cd pc/stackchan-ble-client && bundle exec exe/stackchan-ble-control combo --face $FACE --led "$COLOR $MODE" --side $SIDE`
5. exit code を rake task の exit に propagate (`stackchan-ble-control` が 0 で帰れば 0、それ以外はそのまま)

### 8.2 PASS の定義

* `stackchan-ble-control` が NUS TX notify から ACK `.` を timeout 内に全 frame 分受信して exit 0
* rake task の最後に user 向け文字列 `[smoke] PASS — face=<FACE> LED=<COLOR> <MODE> (<SIDE>) — visual check please` を出力。視認は人間に任せる (CI なし)

### 8.3 Exit code

`stackchan-ble-control` の exit code をそのまま propagate (§4.5 と同 scheme)。

## 9. Test strategy

### 9.1 Host unit test (test-unit + Bundler)

| gem | test |
|---|---|
| `pc/stackchan-ble-client` | `frame_codec_test.rb`, `send_builder_test.rb` (最後勝ち集約 + 順序保持の検証), `hsb_to_rgb_test.rb` (既知サンプル値で table-driven), `client_test.rb` (fake transport で `#send` block 全体) |
| `mrbgems/picoruby-stackchan-protocol` | `frame_parser_test.rb` (既存), `dispatcher_test.rb` (S key 対応の新ケース追加), fake LED の `animate_side` 呼出回数検証 |
| `mrbgems/picoruby-stackchan-led` | `stackchan_led_test.rb` (fill_left/right、animate_side 各 side で正しい range が触られるかを fake py32 mock で検証) |

### 9.2 E2E smoke (実機)

* `rake r2p2:ble_control_smoke` を Phase 3 plan の最終 verification step で実行
* SIDE=left, right, both 各々で目視確認 (left を red にしたら left 半分の LED 6 個だけ赤、right は元の色 or off)
* face neutral/smile/joy/surprised 全部で LCD 描画確認

### 9.3 Regression

* `rake r2p2:build_flash` (R2P2-ESP32 build) は変わらず
* Phase 2 の `r2p2:ble_verify` / `stackchan-ble-verify` exe は削除済み (`r2p2:ble_control_smoke` に統合)

## 10. Out of scope / followup

| Item | 担当 phase | 理由 |
|---|---|---|
| Servo (pan/tilt) frame + driver | Phase 3.5 | `picoruby-scservo` gem 新規 + UART + PY32 P0 制御で別 sub-project |
| AI bridge (rb-foundation-model-mac → ble_control) | Phase 4 | A 完了が前提 |
| WebSocket / Web Bluetooth bridge | 長期 follow-up | Mac CoreBluetooth で Phase 2-3 を fork、Web Bluetooth は別検証路 |
| 12 LED per-pixel addressable DSL | 必要時 | Phase 3 では side (left/right/both) のみ。pixel-level 制御は spec 別途 |
| face と LED の 1-frame combine | 廃止 (Phase 3 で) | block DSL を直線的に保つ。1 frame 内 multi-handler は仕様複雑化のため除外 |
| storage 永続化 (config 等) | 別 sub-project | application.rb の中身は全部 boot 時 init で組む |
| BLE keepalive / 長時間接続 | 不要 (Phase 3) | 1 接続 1 block-send → disconnect の短命接続のみ。Mac CoreBluetooth idle disconnect window (~15-20s) 範囲内で完結 |

## 11. Draft assumptions (実装中に確認)

1. **LED 物理 index の left/right 分割**: `0-5=left / 6-11=right` (Phase 3 verification で目視 fine-tune)
2. **picoruby-ble `peri.start(0)`** が無限 run_loop と等価か (`peri.start(ms)` の 0 が「無期限」を意味するか、API doc / `picoruby-ble` source で要確認、もし違ったら巨大な値 `peri.start(0xFFFFFFFF)` などで代替)
3. **AckSink の queue 排出戦略**: heartbeat_callback で 1 byte ずつ排出 vs `request_can_send_now_event` で push する形のどちらが安定か (ble_smoke.rb の TX notify と同じパターンで OK のはず)
4. **`MODE_TABLE` の `:off`** が device 側 Animator で実装済みか (README には `:off` `clear, immediate apply` と書いてある、要 source 確認)
5. **Mac 側 `corebluetooth_mac` の `write_without_response` の back-pressure**: 連続 4 frame 速射した場合に loss しないか (Phase 2 smoke は 1 frame `ping <seq>` だけだった)

## 12. References

### このリポジトリ内
* `docs/superpowers/specs/2026-05-16-ble-phase3-handoff.md` — Phase 3 handoff (本 spec の親)
* `docs/superpowers/specs/2026-05-16-ble-mac-autonomous-verification-loop-design.md` — Phase 2 design
* `docs/superpowers/specs/2026-05-14-stackchan-protocol-design.md` — frame protocol 起源
* `docs/superpowers/specs/2026-05-14-stackchan-led-protocol-extension-design.md` — LED protocol 拡張、PY32/AW9523 hardware notes
* `mrbgems/picoruby-stackchan-protocol/examples/ble_smoke.rb` — Phase 2 BLE demo (継承元、Phase 3 で削除)
* `mrbgems/picoruby-stackchan-protocol/examples/app.rb` — bring-up smoke、cold-boot init 手順の参照
* `mrbgems/picoruby-stackchan-led/mrblib/stackchan_led.rb` — LED driver、本 spec で拡張対象
* `mrbgems/picoruby-stackchan-protocol/mrblib/stackchan_protocol/dispatcher.rb` — S key 対応で拡張対象
* `pc/stackchan-protocol/exe/stackchan-ble-verify` — Phase 2 verify (Phase 3 で削除)
* `pc/stackchan-protocol/exe/picomodem-upload` — uploader (`lib/deploy/picomodem.rb` へ移植)
* `Rakefile` — r2p2:* task 群、本 spec で再編

### 関連リポジトリ
* `/Users/bash/dev/src/github.com/bash0C7/rb-corebluetooth-mac` — Mac CoreBluetooth Ruby binding (path:local 想定)
* `/Users/bash/dev/src/github.com/bash0C7/R2P2-ESP32` — picoruby-ble fork (BTstack vendored)
* `/Users/bash/dev/src/github.com/picoruby/picoruby` — PicoRuby 本体

### Memory entries (load 済み)
* `feedback_apple_corebluetooth_gap_gatt_filter` — GAP/GATT filter
* `feedback_mac_corebluetooth_gatt_cache_trap` — GATT cache 復旧
* `project_picoruby_ble_heartbeat_tick_one_second` — heartbeat ~1s/tick (NOTIFY period 計算で使う)
* `project_ble_phase2_complete` — Phase 2 完了状態
* `feedback_verify_at_air_interface` — device-side log だけでは不十分、air interface で証明
