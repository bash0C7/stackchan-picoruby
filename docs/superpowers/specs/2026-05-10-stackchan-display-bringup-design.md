# 2026-05-10 — stackchan-display bring-up 設計書

## 1. プロジェクト全体の位置づけ

`stackchan-picoruby` は M5Stack 公式 StackChan を [PicoRuby](https://github.com/picoruby/picoruby)（[R2P2-ESP32](https://github.com/picoruby/R2P2-ESP32) on ESP32-S3）で動かすための個人ポートプロジェクト。最終形は「PC 側で Apple Foundation Model を使ったローカル AI が判断し、StackChan が I/O 端末としてシリアル経由でアバター表現する」アーキテクチャ。

このリポジトリ自体はモノレポで、内部に複数の汎用 PicoRuby mrbgem (`picoruby-<device>`) を抱える。確立後に各 mrbgem を独立リポジトリにスピンアウトし、upstream (`picoruby/picoruby`) に PR で還流させる構想。

**この spec は、その第一歩** — ハードウェア起動 + 1 つ目のドライバー (`picoruby-ili9342`) + ｽﾀｯｸﾁｬﾝの顔静止画表示まで。

## 2. ゴール（受け入れ基準）

実機 M5Stack CoreS3 上で以下が動くこと。

1. `bash0C7/R2P2-ESP32` (mruby VM) でビルドしたファームを CoreS3 にフラッシュ → R2P2 シェル (REPL) が USB-Serial 経由で起動する
2. `mrbgems/picoruby-ili9342/` を本リポジトリ内に新規し、R2P2-ESP32 ビルドツリーに取り込んでフラッシュ済みファームから `require 'ili9342'` で読み込める
3. REPL から以下が動作：
   ```ruby
   require 'ili9342'
   d = ILI9342.new(spi: spi_instance, dc_pin: D, cs_pin: C, rst_pin: R, bl_pin: B, width: 320, height: 240, rotation: :landscape)
   d.fill(0x0000)            # 黒
   d.fill(0xF800)            # 赤
   d.draw_pixel(160, 120, 0xFFFF)
   d.draw_rect(10, 10, 50, 30, 0x07E0, fill: true)
   d.draw_line(0, 0, 319, 239, 0xFFFF)
   d.draw_ellipse(160, 120, 40, 30, 0x001F, fill: false)
   ```
4. `examples/avatar_demo.rb` を実行 → 3 つの表情（neutral / smile / joy）が 5 秒間隔で切り替わる
5. `examples/face_neutral.rb` `face_smile.rb` `face_joy.rb` 単発実行で対応する顔が表示される
6. `home/app.rb` として `examples/face_neutral.rb` を配置 → 電源投入で自動的に neutral 顔が立ち上がる

## 3. スコープ

### 3.1 含む

- **(A) ハードウェア bring-up**：CoreS3 で `bash0C7/R2P2-ESP32` (mruby VM) のフラッシュ手順確立
  - SoC ターゲット: `setup_esp32s3`
  - sdkconfig 組合せ: `usb_console + spiram` （CoreS3 は外付け USB-UART 持たないので JTAG console、PSRAM は OPI）
  - ESP-IDF v5.4 前提
  - `bash0C7/R2P2-ESP32` は origin のみ設定済み、`upstream = picoruby/R2P2-ESP32` を最初に追加
  - 必要なら CoreS3 用の sdkconfig フラグメント (`sdkconfigs/cores3` など) を bash0C7 fork 側に追加し、それを使う
- **(B) 新規 mrbgem `picoruby-ili9342`** を `mrbgems/picoruby-ili9342/` に作成
  - **API**:
    - `ILI9342.new(spi:, dc_pin:, cs_pin:, rst_pin:, bl_pin:, width:, height:, rotation:)`
    - `#fill(rgb565)`
    - `#draw_pixel(x, y, rgb565)`
    - `#draw_rect(x, y, w, h, rgb565, fill: false)`
    - `#draw_line(x0, y0, x1, y1, rgb565)`
    - `#draw_ellipse(cx, cy, rx, ry, rgb565, fill: false)`
    - `#set_backlight(level)`（true/false 二値で十分）
  - **実装方針**: Pure Ruby ファースト。`picoruby-spi` と `picoruby-gpio` に依存。C-mrbgem 化は速度問題が出てから次 spec で。
  - **初期化シーケンス・ピン番号**: M5Stack 公式 `../StackChan/firmware/main/hal/board/stackchan_display.cc` を Read で参照して抽出
  - **レイアウト**: `mrbgem.rake` / `mrblib/ili9342.rb` / `sig/ili9342.rbs` / `examples/` / `test/` / `Rakefile` / `Gemfile` / `README.md`（`bash0C7/picoruby-mpu6886` 構造踏襲）
- **(C) bash0C7/R2P2-ESP32 のビルドへの組込み**
  - `components/picoruby-esp32/CMakeLists.txt` の port 列挙に新 mrbgem ソースを追加
  - `build_config/xtensa-esp-picoruby.rb` の gembox に `picoruby-ili9342` を追加
  - 取込み方式は **plan 段階で決定**：path 直書き (`gemdir: '/Users/bash/dev/src/github.com/m5stack/stackchan-picoruby/mrbgems/picoruby-ili9342'`) を第一候補、増えたら git submodule 化を検討
- **(D) examples** （`mrbgems/picoruby-ili9342/examples/` に配置）
  - `black_fill.rb` — 黒一色塗り（最小確認）
  - `color_cycle.rb` — 赤→緑→青を 1 秒ごと
  - `face_neutral.rb` — neutral 顔（目 + まっすぐな口）
  - `face_smile.rb` — smile 顔（同じ目 + 少しにっこり口）
  - `face_joy.rb` — joy 顔（同じ目 + 大きくにっこり口）
  - `avatar_demo.rb` — 3 表情を 5 秒ごと巡回
  - 顔描画ロジックは `../StackChan/firmware/main/stackchan/avatar/skins/default/{eyes,mouth}.cpp` を Read して procedural 描画を Ruby に移植
- **(E) テスト**
  - CRuby 側 `test-unit` で `bundle exec rake test`
  - SPI/GPIO をモックして、初期化バイトシーケンスが ILI9342 データシートと一致することを検証
  - RGB565 変換 (`rgb888_to_rgb565`) の数学的正しさ
  - 描画関数の境界条件（画面外座標のクリップ等）
- **(F) ドキュメント**
  - `mrbgems/picoruby-ili9342/README.md` — gem の使い方、API、CoreS3 ピン例
  - リポジトリルートに `README.md`（最小限：プロジェクト概要・現状の対応範囲・次の予定）

### 3.2 含まない（次 spec 以降）

| 項目 | 想定 spec |
|---|---|
| 表情アニメーション（瞬き / 口パク / 揺れ） | `picoruby-ili9342` 拡張 spec |
| 感情マーク (decorators: angry / dizzy / heart / shy / sweat) | 「感情表現拡張」 spec |
| BMI270 + BMM150 ドライバー | `picoruby-bmi270` / `picoruby-bmm150` spec |
| FT6336 タッチドライバー | `picoruby-ft6336` spec |
| 頭タッチ (Si12T or 専用 IC) ドライバー | 公式 hal を読んでチップ確定後 spec |
| SCServo (UART 駆動の 2 軸サーボ) ドライバー | `picoruby-scservo` spec |
| SK6812 RGB LED 12 個 | gembox 既存の `adafruit_sk6812` ラッパー spec |
| USB-Serial 経由のホスト⇄StackChan プロトコル定義 | 「stackchan-protocol」 spec |
| BLE-Serial 対応（ESP32 BLE port を picoruby に新規実装） | 「ESP32 BLE port」 spec、最も重い |
| WiFi 経由通信 | BLE が立った後の検討 |
| カメラ (GC0308) — 「PicoRuby でカメラ制御は誰もまだやってない未知の世界」 | 遠い将来 |
| マイク / スピーカー (I2S) | 遠い将来 |
| PC 側 Ruby クライアント (`rb-foundation-model-mac` 連携) | StackChan 側プロトコル確立後 |
| 各 mrbgem の独立リポ化と upstream `picoruby/picoruby` への PR | 動作検証完了後の運用フェーズ |

## 4. アーキテクチャ

### 4.1 リポジトリ構成

```
stackchan-picoruby/
├── CLAUDE.md
├── README.md                            ← この spec で作成
├── docs/superpowers/
│   ├── specs/2026-05-10-stackchan-display-bringup-design.md
│   └── plans/                           ← writing-plans skill で生成
└── mrbgems/
    └── picoruby-ili9342/
        ├── mrbgem.rake
        ├── README.md
        ├── Rakefile
        ├── Gemfile
        ├── mrblib/ili9342.rb
        ├── sig/ili9342.rbs
        ├── examples/
        │   ├── black_fill.rb
        │   ├── color_cycle.rb
        │   ├── face_neutral.rb
        │   ├── face_smile.rb
        │   ├── face_joy.rb
        │   └── avatar_demo.rb
        └── test/
            └── ili9342_test.rb
```

### 4.2 関連リポジトリの役割

| リポジトリ | 役割 | アクセス |
|---|---|---|
| `m5stack/StackChan` (cloned at `../StackChan`) | 公式 C++ ファーム。ピン配置 / 初期化シーケンス / 顔描画ロジックの参照元 | **Read のみ** |
| `m5stack/stackchan-picoruby` (本リポジトリ) | モノレポ、ドライバー mrbgem 群と spec/plan | 開発対象 |
| `bash0C7/picoruby` (`origin=bash0C7, upstream=picoruby/picoruby`) | PicoRuby 本体の作業フォーク | 必要に応じ作業ブランチ作成 |
| `bash0C7/R2P2-ESP32` (`origin=bash0C7`、upstream は spec 内で追加) | ESP32 ファームの作業フォーク。本 spec で CoreS3 ビルド設定を追加 | 開発対象 |
| `picoruby/picoruby`, `picoruby/R2P2-ESP32` | upstream 公式 | upstream remote 経由で参照 |

### 4.3 描画スタック

```
[examples/face_*.rb]
        │
        ▼
[ILI9342 (Pure Ruby)]
        │   draw_pixel / draw_line / draw_rect / draw_ellipse / fill
        ▼
[picoruby-spi] [picoruby-gpio]
        │
        ▼
[ESP32-S3 SPI / GPIO ハード]
        │
        ▼
[ILI9342 LCD コントローラ → 320x240 IPS パネル]
```

### 4.4 顔描画モデル

ｽﾀｯｸﾁｬﾝの素朴さを尊重して **目と口だけ** で表現。decorator レイヤーは持たない。

- **背景**: 黒で fill
- **eyes layer**: 左右対称、3 表情とも **同一**（瞳の動き・閉眼は本 spec 範囲外）。大きめの白塗り楕円 2 つ。
- **mouth layer**: 画面中央下寄り、口角の角度 / カーブ高さで表情を切替
  - `neutral`: まっすぐな水平線
  - `smile`: 少しにっこり（控えめな上向きカーブ）
  - `joy`: 大きくにっこり（しっかり上向きカーブ）

口のカーブは「中点を `mouth_y` 基準にして両端から `delta_y` ピクセル上に持ち上げた `draw_line` 2 本」で procedural に描く。`delta_y` の値で 3 表情を分ける（neutral=0、smile=小、joy=大）。具体ピクセル数は plan で公式 `mouth.cpp` を読んで決定。

## 5. 実装方針

### 5.1 言語

Pure Ruby ファースト。理由：

- ILI9342 初期化は数十バイトの SPI 送信で済む
- 描画関数は picoruby-ssd1306 と同様の整数演算で十分
- C-mrbgem 化は SPI bulk 転送速度が許容外と判明した時点で次 spec 対応（YAGNI）

### 5.2 依存 picogem

- `picoruby-spi` — SPI 通信。`SPI.new(unit: :ESP32_SPI2_HOST, frequency: ..., sck_pin:, copi_pin:, cs_pin:, mode: 0)` で初期化
- `picoruby-gpio` — DC/RST/BL の制御
- `picoruby-machine` — `Machine.delay_ms` で初期化シーケンス間 wait

### 5.3 初期化シーケンス・ピン

**完全な値は plan 段階で `../StackChan/firmware/main/hal/board/stackchan_display.cc` を読んで確定**。spec 段階では「公式から取って合わせる」とだけ約束。

### 5.4 RGB565 ヘルパ

mrbgem 内に：
```ruby
ILI9342::Color::RED   = 0xF800
ILI9342::Color::GREEN = 0x07E0
ILI9342::Color::BLUE  = 0x001F
ILI9342::Color::WHITE = 0xFFFF
ILI9342::Color::BLACK = 0x0000
```
+ `ILI9342.rgb(r, g, b)` で 8/8/8 → 565 変換ユーティリティ。

### 5.5 `rotation:` の許容値

`:portrait` / `:landscape` / `:portrait_flip` / `:landscape_flip` の 4 シンボルを受ける。実機 CoreS3 では `:landscape` が顔向き。MADCTL レジスタへのマッピングは plan で確定。

## 6. テスト戦略

### 6.1 CRuby 側ユニットテスト (`test-unit`)

- SPI / GPIO クラスを Ruby のテストダブルで差し替え
- 初期化シーケンスを実行して、書き込まれたコマンドバイト列がデータシート通りか
- `rgb` 変換の数学的正しさ（既知ペアで検証）
- `draw_rect(fill: true)` で書き込まれるピクセル数 = w * h
- 画面外座標のクリップ（負座標 / `>= width` / `>= height`）

### 6.2 実機検証

- examples を実機 CoreS3 で 1 つずつ実行し、目視確認
- README に「期待される画面」をテキスト記述（写真は次フェーズ）
- フィル全画面の所要時間を `Machine.uptime_us` で計測 → README に記録（C 化要否判断のベースライン）

## 7. リスクと open question

| # | 内容 | 対策 |
|---|---|---|
| R1 | CoreS3 で R2P2-ESP32 が動くのは PicoRuby 開発者から太鼓判もらってるが実機未検証 | plan 最初のタスクで「素の R2P2-ESP32 をフラッシュ → REPL 起動」を最優先確認 |
| R2 | `bash0C7/R2P2-ESP32` に upstream remote 未設定 | plan ステップ 0 で `git remote add upstream https://github.com/picoruby/R2P2-ESP32.git` |
| R3 | CoreS3 用 sdkconfig フラグメント (`sdkconfigs/cores3`) は upstream にない | bash0C7 fork に必要なら追加。動作確認後に upstream PR 提出は別 spec |
| R4 | `stackchan-picoruby/mrbgems/` を R2P2-ESP32 ビルドに混ぜる方法（path 直書き vs submodule）は plan 段階で確定 | plan で 2 案検証、シンプルな path 直書きから |
| R5 | ILI9342 の Pure Ruby SPI フィル速度が許容範囲かは未測定 | 出たら次 spec で C 化。本 spec では計測値を README に書くだけ |
| R6 | M5Stack 公式 hal の C++ コードは LGPL 等のライセンス確認していない | plan 序盤で `../StackChan/LICENSE` 確認、必要ならピン定数のみ参照に留める |
| R7 | mruby VM (`picoruby` ビルド) で `picoruby-spi` ESP32 port が安定動作するかは未検証（直近 PR #119 でやっと入った） | 不安定なら femtoruby (mruby/c) ビルドに切替、その判断は plan で |

## 8. 完了の判定（再掲）

「セクション 2. ゴール」の 6 項目すべて実機確認できたら本 spec は終了。完了後、writing-plans skill で詳細実装計画を作成し、subagent-driven-development で順次実行する想定。

## 9. 後続 spec 候補（メモのみ）

優先順位案：

1. **stackchan-protocol** — USB-Serial プロトコル定義 + StackChan 側ディスパッチャ + PC 側 Ruby ラッパー（rb-foundation-model-mac との接続点）
2. **picoruby-bmi270** — IMU、bash0C7/picoruby-mpu6886 構造踏襲
3. **picoruby-scservo** — UART 駆動の 2 軸サーボ
4. **picoruby-ili9342 拡張** — 表情アニメーション、感情マーク (decorators)
5. **picoruby-ft6336** — 静電容量タッチ
6. **picoruby-sk6812 ラッパー** — 12 個 RGB LED
7. **picoruby-stackchan-headtouch** — 頭タッチ 3 ゾーン（チップ確定後）
8. **ESP32 BLE port** — picoruby/picoruby に ESP32 用 BLE mrbgem を新規（最重量）
