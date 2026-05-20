# 2026-05-14 — stackchan-protocol 設計書

## 1. プロジェクト位置づけ

`stackchan-protocol` は `2026-05-10-stackchan-display-bringup-design.md` の section 9 で「次やる spec 第 1 順位」とされた **PC ⇔ StackChan の最小通信レイヤ**。以降の `picoruby-bmi270` / `picoruby-scservo` / `stackchan-avatar` (旧称 picoruby-ili9342 拡張) など全機能アプリは、本 protocol の上に乗せる「要石」。

最終形は spec section 1 の通り「PC 側で Apple Foundation Model を使ったローカル AI が判断し、StackChan が I/O 端末としてシリアル経由でアバター表現する」。本 spec はその一歩目として **顔切替コマンド 1 つだけ**動かす最小レイヤを確立する。

## 2. ゴール（受け入れ基準）

実機 M5Stack CoreS3 上で以下が動くこと。

1. CoreS3 を USB-C 接続 → R2P2-ESP32 ファーム（`picoruby-stackchan-protocol` 込み）が boot → `/home/app.rb` が autostart → 画面に **neutral 顔**が表示される（PC 操作なし）
2. macOS で `cd pc/stackchan-protocol && bundle install` 成功
3. `bundle exec stackchan-control --port /dev/cu.usbmodem1101 smile` → 画面が smile 顔に切替
4. `... neutral` / `... joy` でそれぞれ切替確認
5. `... raw 9` → 画面はそのまま、PC 側に `DeviceError` が出る（StackChan が `'?'` を 1 byte 返す）
6. StackChan 側は autostart 一本で完結、irb / 対話実行は一切使わない

## 3. スコープ

### 3.1 含む

- **(A) StackChan 側 mrbgem `picoruby-stackchan-protocol`**：dispatcher + 顔描画ロジック + examples/app.rb + host テスト
- **(B) PC 側 gem-like `pc/stackchan-protocol/`**：Client + CLI `stackchan-control` + host テスト
- **(C) R2P2-ESP32 build_config 追加**：`bash0C7/R2P2-ESP32` 側に `conf.gem path:` 1 行
- **(D) 検証手順 doc**：新規 `docs/STACKCHAN_PROTOCOL_VERIFICATION.md`、`HARDWARE_VERIFICATION.md` の display 側と独立
- **(E) リポルート README** の status table 更新（protocol 行追加）

### 3.2 含まない（次 spec 以降）

| 項目 | 想定 spec |
|---|---|
| BLE-Serial 対応 | 「ESP32 BLE port」spec 立上げ後 |
| IMU event / サーボ command の vocabulary 拡張 | stackchan-protocol v1 |
| 接続復帰 / リトライ / レートリミット | v1 |
| StackChan→PC の hello / version 報告 | v1 |
| Foundation Model 連携 (Apple Foundation Model + 顔判断) | rb-foundation-model-mac 連携 spec |
| stackchan-avatar アプリ層（瞬き / 口パク / decorator） | 別 spec（picoruby-ili9342 拡張から改題） |
| TLV / multi-byte command | v1 以降 |
| 暗号化 / 認証 | 検討対象外 |

### 3.3 picoruby-ili9342 との分離原則

picoruby-ili9342 は **汎用 ILI9342 ドライバ**として StackChan 用途以外でも使える状態に据え置く。**StackChan 固有の顔描画ロジック（眼・口の procedural 描画）は picoruby-stackchan-protocol 側に持つ**。今 picoruby-ili9342/examples/_face.rb 等にあるロジックは本 spec で picoruby-stackchan-protocol に移送する。

## 4. アーキテクチャ

### 4.1 データフロー

```
[macOS] bundle exec stackchan-control smile
        │
        ▼
[pc/stackchan-protocol] StackchanProtocol::Client#set_face(:smile)
        │  → FACE_BYTES.fetch(:smile) == '1'
        ▼
[uart gem (tenderlove/uart)] serial.write('1')
        │
        ▼  USB CDC ACM
        │  /dev/cu.usbmodem1101, 115200 baud
        │
[CoreS3] R2P2-ESP32 boot → load $HOME/app.rb (autostart)
        │
        ▼
[picoruby-stackchan-protocol] Dispatcher#run
        │  STDIN.read(1) → '1'
        │  → handle_byte('1') → FACES['1'] == Face::Smile
        │  → Face::Smile.new.draw(display)
        ▼  (未定義 byte 時) STDOUT.write('?')
[picoruby-ili9342] d.fill / d.draw_ellipse / d.draw_line
        ▼
[ILI9342 LCD] 320×240 IPS panel
```

### 4.2 通信媒体

- USB-Serial 一本（USB CDC ACM、`/dev/cu.usbmodem1101` on macOS）
- baud 115200（USB CDC は実際 baud 無視されるが API には渡す）
- BLE-Serial は ESP32 BLE port が picoruby に立った後の次 spec

### 4.3 リポジトリ構成（本 spec で作成・修正される範囲）

```
stackchan-picoruby/
├── docs/superpowers/
│   ├── specs/2026-05-14-stackchan-protocol-design.md   ← 本 spec
│   └── plans/2026-05-14-stackchan-protocol.md          ← writing-plans で生成
├── docs/STACKCHAN_PROTOCOL_VERIFICATION.md             ← 検証手順
├── mrbgems/
│   └── picoruby-stackchan-protocol/                    ← 新規
└── pc/
    └── stackchan-protocol/                             ← 新規
```

`bash0C7/R2P2-ESP32` 側：
- `components/picoruby-esp32/build_config/xtensa-esp-picoruby.rb` に `conf.gem path:` 1 行追加

## 5. メッセージ仕様 (v0)

### 5.1 Wire format

**1 byte 固定長、ASCII、区切り文字なし。** 双方向で同一 byte 空間を共有。

### 5.2 Vocabulary (v0)

**PC → StackChan：**

| byte | ASCII | 意味 |
|---|---|---|
| 0x30 | `'0'` | set_face neutral |
| 0x31 | `'1'` | set_face smile |
| 0x32 | `'2'` | set_face joy |

**StackChan → PC：**

| byte | ASCII | 意味 |
|---|---|---|
| 0x3F | `'?'` | error（未定義 byte / 内部例外 / 描画失敗をすべて統合） |

成功時は silent（fire-and-forget 風）。エラー時のみ `'?'` を 1 byte。

### 5.3 同期モデル

- StackChan 側は `STDIN.read(1)` ブロッキング loop。1 byte 受けたら順次処理（描画 100〜数百 ms かかる）
- PC 側はノンブロッキング書き込み、ack 待ちなし（`'?'` は来たら受ける、来なくても続行）
- レートリミットなし、PC 側ユーザ操作頻度に任せる

### 5.4 ノイズハンドリング

R2P2-ESP32 の boot 時 stdout には ESP-IDF 起動ログ + R2P2 banner が流れる。これは app.rb の loop が始まる前のフェーズで PC 側にも流れる。

- PC 側 `Client#drain(timeout:)` で接続直後にバッファ吸い出し
- app.rb 起動後の loop で **定義されてない byte（`\r` / `\n` / 余分なバイト含む）は全部 `'?'` 返却**で統一

### 5.5 起動シーケンス（MVP）

- StackChan boot 時の hello は送らない（YAGNI）
- PC 側は `open` 成功 + 最初の `write` で接続 OK とみなす
- 接続失敗（port 消滅等）は tenderlove/uart の例外で死ぬ

### 5.6 v1 以降の拡張余地（メモ、本 spec scope 外）

- ASCII 数字 `'3'`〜`'9'` 余り → 顔追加 7 種
- `'a'`〜`'z'` → サーボ / LED / IMU 周辺コマンド
- 大文字 `'A'`〜`'Z'` → StackChan 発の event（IMU 値、touch event）
- それ以上は v1 で TLV (Type-Length-Value) に拡張するか別 spec で議論

## 6. StackChan 側 mrbgem 構造

### 6.1 mrbgem 名称・責任範囲

`mrbgems/picoruby-stackchan-protocol/`。責任：

- **protocol layer**：`STDIN.read(1)` → vocabulary 解釈 → action 呼び出し / 不明 byte で `STDOUT.write('?')`
- **face rendering layer**：neutral / smile / joy の procedural 描画（既存 picoruby-ili9342/examples/\_face.rb 系を移送）

### 6.2 ファイル layout（picoruby-mpu6886 / picoruby-ili9342 踏襲）

```
mrbgems/picoruby-stackchan-protocol/
├── README.md
├── Gemfile
├── Rakefile
├── LICENSE
├── mrbgem.rake
├── mrblib/
│   └── stackchan_protocol.rb     # Dispatcher + Face::{Base,Neutral,Smile,Joy}
├── sig/
│   └── stackchan_protocol.rbs
├── examples/
│   └── app.rb                    # SPI/GPIO/ILI9342 setup + Dispatcher.new.run
└── test/
    ├── test_helper.rb
    ├── fake_display.rb           # display I/F の mock
    ├── fake_stdio.rb             # STDIN.read(1) / STDOUT.write 制御
    └── stackchan_protocol_test.rb
```

### 6.3 公開 API スケッチ

```ruby
module StackchanProtocol
  class Dispatcher
    FACES = { '0' => Face::Neutral, '1' => Face::Smile, '2' => Face::Joy }

    def initialize(display:, stdin: $stdin, stdout: $stdout)
    end

    def run                # ブロッキング loop
    end

    def handle_byte(byte)  # 単一 byte 処理、テスト用 entry
    end
  end

  module Face
    class Base
      def draw_eyes(display); end
      def draw_mouth(display, delta_y); end
    end
    class Neutral < Base; DELTA_Y = 0;  def draw(d); ...; end; end
    class Smile   < Base; DELTA_Y = 8;  def draw(d); ...; end; end
    class Joy     < Base; DELTA_Y = 16; def draw(d); ...; end; end
  end
end
```

`Dispatcher#handle_byte` を public：mock display + fake stdin で **1 byte ずつ TDD**。

### 6.4 依存 mrbgem

- `picoruby-ili9342` (path、姉妹 mrbgem)
- `picoruby-spi` / `picoruby-gpio` は **examples/app.rb 側のみ使う**（Dispatcher 本体は display インスタンスを外から受ける）

### 6.5 examples/app.rb の構造

```ruby
require 'ili9342'
require 'stackchan_protocol'

spi = SPI.new(unit: :ESP32_SPI3_HOST, frequency: 40_000_000,
              sck_pin: 36, copi_pin: 37, mode: 2)
dc  = GPIO.new(35, GPIO::OUT)
cs  = GPIO.new(3,  GPIO::OUT)
rst = GPIO.new(1,  GPIO::OUT)   # AW9523 経由は別 spec、当面 placeholder
bl  = GPIO.new(2,  GPIO::OUT)   # AXP2101 経由は別 spec、USB 電源で点灯
display = ILI9342.new(spi: spi, dc_pin: dc, cs_pin: cs, rst_pin: rst, bl_pin: bl,
                      width: 320, height: 240, rotation: :landscape)

StackchanProtocol::Face::Neutral.new.draw(display)   # boot 直後の welcome face

StackchanProtocol::Dispatcher.new(display: display).run
```

### 6.6 R2P2-ESP32 build 統合

`bash0C7/R2P2-ESP32` の `components/picoruby-esp32/build_config/xtensa-esp-picoruby.rb` に 1 行追加：

```ruby
conf.gem path: '/Users/bash/dev/src/github.com/m5stack/stackchan-picoruby/mrbgems/picoruby-stackchan-protocol'
```

## 7. PC 側 gem-like 構造

### 7.1 配置場所・gem 名称

`pc/stackchan-protocol/`（monorepo 内、`mrbgems/` と対称的に PC 側 directory）。gem 名 `stackchan-protocol`。rubygems.org publish は YAGNI、ローカル Bundler 管理（`bundle install --path vendor/bundle`）。

### 7.2 ファイル layout

```
pc/stackchan-protocol/
├── README.md
├── Gemfile
├── stackchan-protocol.gemspec
├── Rakefile
├── lib/
│   ├── stackchan_protocol.rb
│   └── stackchan_protocol/
│       ├── version.rb
│       ├── client.rb
│       └── face_table.rb        # FACE_BYTES = { neutral: '0', smile: '1', joy: '2' }
├── exe/
│   └── stackchan-control        # CLI
└── test/
    ├── test_helper.rb
    ├── fake_uart.rb
    └── client_test.rb
```

### 7.3 公開 API

```ruby
module StackchanProtocol
  class DeviceError < StandardError; end

  FACE_BYTES = { neutral: '0', smile: '1', joy: '2' }.freeze

  class Client
    def initialize(port:, baud: 115_200, ack_timeout: 0.5)
    end

    def open(&block)              # UART.open ラップ、block-yield
    end

    def set_face(name)            # name in [:neutral, :smile, :joy]
                                  # ack_timeout 内に '?' なら DeviceError
                                  # 来なければ silent return nil
    end

    def raw_send(byte)            # debug 用、生 byte 送信
    end

    def drain(timeout: 1.0)       # 接続直後の boot ログ吸い出し
    end
  end
end
```

### 7.4 ack タイムアウト実装

tenderlove/uart の `wait_readable` は timeout 引数なし → **`IO.select([io], nil, nil, ack_timeout)` で代替**。serial fd が IO-compatible でないなら uart gem に accessor を生やす（PR 候補）。

`set_face` の流れ：

1. `serial.write(FACE_BYTES.fetch(name))`
2. `IO.select(...)` で 500ms 待機
3. ready なら `serial.read(1)` → `'?'` なら `raise DeviceError`、それ以外は noise として無視
4. ready ちゃうなら成功扱いで return

### 7.5 CLI 仕様（exe/stackchan-control）

```sh
$ bundle exec stackchan-control --port /dev/cu.usbmodem1101 neutral
$ bundle exec stackchan-control --port /dev/cu.usbmodem1101 smile
$ bundle exec stackchan-control --port /dev/cu.usbmodem1101 joy
$ bundle exec stackchan-control --port /dev/cu.usbmodem1101 raw 9   # for '?' path test
```

- 引数 `<face_name>` または `raw <byte>`
- `--port` 省略時は env `STACKCHAN_PORT`、それも無ければエラー
- 対話 REPL モードは YAGNI

### 7.6 依存

- runtime: `uart` (tenderlove/uart) → 自動で `ruby-termios` も入る
- dev: `test-unit`, `rake`

## 8. 動作確認手順（実機）

1. CoreS3 を USB-C 接続、`/dev/cu.usbmodem1101` enumerate 確認
2. `bash0C7/R2P2-ESP32` の `xtensa-esp-picoruby.rb` に `picoruby-stackchan-protocol` の `conf.gem path:` 1 行追加
3. `rake r2p2:build_flash`
4. `mrbgems/picoruby-stackchan-protocol/examples/app.rb` を `https://picoruby.org/terminal` で `/home/app.rb` に Upload（PicoModem 経由、`Plain` mode）
5. CoreS3 reset → boot 直後 neutral 顔表示確認
6. PC で `cd pc/stackchan-protocol && bundle install`
7. `bundle exec stackchan-control --port /dev/cu.usbmodem1101 smile` → smile 顔
8. `... neutral` / `... joy` で切替確認
9. `... raw 9` → PC に `DeviceError` 出力 + 画面そのまま

## 9. テスト戦略

### 9.1 StackChan 側（CRuby host テスト）

`bundle exec rake test`：

- `Dispatcher#handle_byte('0')` → mock display に neutral 描画 sequence（`fill(BLACK)` + 2 ellipse + 2 line）が記録される
- `handle_byte('9')` → mock STDOUT に `'?'` が書かれる
- `handle_byte("\n")`（boot ノイズ想定）→ `'?'`
- `Face::Neutral / Smile / Joy` の `draw` を直接呼んで `fill / draw_ellipse / draw_line` 呼び出し順を assert
- mpu6886 / ili9342 で確立した FakeXxx pattern を踏襲

### 9.2 PC 側（CRuby host テスト）

`bundle exec rake test`：

- `FakeUart` を `Client.new(uart_class: FakeUart, ...)` で注入
- `Client#set_face(:smile)` → FakeUart の write 履歴に `'1'` 記録
- FakeUart に `'?'` を仕込む → `Client#set_face(:smile)` が `DeviceError` raise
- `Client#set_face(:unknown)` → `KeyError`
- `Client#drain(timeout: 0.1)` の `IO.select` タイムアウト動作

### 9.3 実機検証

section 8 の手順をそのまま実行。pass criterion は section 2 のゴール 6 項目。

## 10. エラー戦略

**StackChan 側**：
- 未定義 byte：`STDOUT.write('?')` だけ。loop continue
- 内部例外（描画失敗等）：`rescue => e; STDOUT.write('?'); next` で loop 死守、クラッシュ禁止
- デバッグ用ログを stderr / 別 byte に出すかは v1 で議論

**PC 側**：
- tenderlove/uart 例外（port 消滅等）：raise → CLI で catch → stderr + exit 1
- `set_face(:unknown_symbol)`：`KeyError`（`FACE_BYTES.fetch`）
- ack `'?'` 受信：`DeviceError` raise

## 11. リスクと open question

| # | 内容 | 結果（2026-05-14 実機検証） |
|---|---|---|
| R1 | tenderlove/uart の `wait_readable` に timeout 引数なし | ✅ 解決。`UART.open` が返すのは普通の `File`、`io.wait_readable(timeout)` がそのまま使える |
| R2 | app.rb autostart 後の STDOUT に R2P2 boot ログが混ざるか不明 | ✅ 問題なし。autostart で `Dispatcher#run` が STDIN を占有、boot 後の I (NNNN) ログは ack 通信に乗らない |
| R3 | PicoRuby 4.0 系の `STDIN.read(1)` がブロッキングかノンブロッキングか不明 | ✅ blocking。`main_task: Returned from app_main()` が出ず Dispatcher が永続化 |
| R4 | `STDOUT.write('?')` の flush 挙動 | ✅ flush 不要。`$stdout` は `:sync=` を持たんが、`write('?')` は即 PC に到達（probe で 1 byte ack 取得確認） |
| R5 | app.rb autostart が STDIN/STDOUT を shell から奪えるか | ✅ 奪える。shell prompt `$>` は autostart 後一切出ず、PC 側 1 byte がそのまま Dispatcher に届く |
| R6 | picoruby-ili9342 が「実機未検証」状態（display bring-up は別 session で物理接続待ち） | ✅ 解決。同セッションで CoreS3 上で `ILI9342.new` 成功、`fill / draw_ellipse / draw_line` 動作、20 連続 face switch 安定 |

### 実機検証で判明した build infra 課題（spec 外、Rakefile/CLAUDE.md 側で対処）

- **`conf.gem path:` は picoruby の `MRuby::LoadGems` で未対応**（`Need to set exactly ONE of git, github, bitbucket, mgem, core, or gemdir`）。`gemdir:` に統一する。R2P2-ESP32 fork 側 `build_config/xtensa-esp-picoruby.rb` の表記を修正済み
- **gem 追加後は `rake r2p2:setup` 必須**。`idf.py build` 単独では picoruby/build の `gem_init.c` / `picogem_init.c` が再生成されず、新規 gem が組み込まれない（boot 時 LoadError）
- **require 名 = gem 名から `picoruby-` を strip した形**。`picoruby-stackchan-protocol` → `require 'stackchan-protocol'` (hyphen)。host テストの `require 'stackchan_protocol'` (underscore) はファイル名解決経由で問題なし
- **port は機体によって `/dev/cu.usbmodem101` or `1101`**。Rakefile / 検証 doc は ESPPORT 環境変数で上書き可

## Servo protocol

Servo control was redesigned 2026-05-21 to use direction-key + magnitude
(`<YL:N,YR:N,PU:N>` with `<torque:on|off>` and `<selftest:run>` system frames).
See `2026-05-21-cold-boot-torque-off-and-normalized-protocol-design.md` for the
canonical frame syntax and semantics.

## 12. 完了の判定（再掲）

「セクション 2. ゴール」の 6 項目すべて実機確認できたら本 spec は終了。

## 13. 後続 spec 候補

1. **stackchan-avatar** — 表情アニメ / decorator アプリ（旧称 picoruby-ili9342 拡張、`picoruby-stackchan-protocol` を depend）
2. **picoruby-bmi270 + bmm150** — IMU
3. **picoruby-scservo** — UART サーボ
4. **stackchan-protocol v1** — IMU event / サーボ command vocabulary 追加 + hello/version + 再接続
5. **rb-foundation-model-mac 連携** — PC 側 Foundation Model + Client 統合
6. **picoruby-ft6336** — タッチ
7. **picoruby-sk6812 ラッパー** — 12 個 RGB LED
8. **ESP32 BLE port (picoruby 本体)** — BLE-serial 対応の前提
