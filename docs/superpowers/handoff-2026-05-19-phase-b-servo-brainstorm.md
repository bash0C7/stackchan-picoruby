# Phase B (servo) ブレインストーミング ハンドオフ (2026-05-19)

**次セッションでのトリガー文:** user が「Phase B 始めて」「servo の brainstorming やろう」と言ったら `superpowers:brainstorming` skill を起動して Phase B のスコープを詰める。**まだ実装フェーズに入らない**。

## なぜこの handoff があるか

2026-05-19 セッションで Design D 実装 + Phase A HITL クロージャ完了。Phase A = 顔の感情表現 (Sad / Angry 含む 6 face)。次は Phase B = サーボによる首振り・チルト動作で、kawaii-ai-robot-design の中で「身体表現」レイヤを担う。

## 前提となる状態 (Phase A 終了時点)

| 領域 | 状態 |
|---|---|
| application.rb business logic | `StackchanApp::Face` / `StackchanApp::Dispatcher` に集約済 (Design D Task 3-4) |
| Dispatcher frame protocol | `F`=face / `M`=led mode / `S`=side / `C`=color の 4 key、F:0..5 + F:6 (Closed) |
| firmware mrbgem | `picoruby-stackchan-protocol` は `FrameParser` のみ残存 (Design D Task 7) |
| deploy 経路 | `stackchan-device-*` skill 群 (10 atomic + 5 chain) で標準化済 |
| device 状態 | 最終 BLE コマンド = `combo --face angry --led "red blink"`、Angry face + 赤点滅 LED 表示中 |
| host test | 19/19 PASS, 0 omit |

## Phase B のスコープ仮説 (brainstorming で詰める対象)

memory `kawaii-ai-phase-b-servo` (まだ memory 作成されてない、Phase A 内 `[[link]]` のみ) に書かれた予想:

- **picoruby-scservo new mrbgem**: SCServo プロトコル (FEETECH 系) の純 PicoRuby 実装。UART 経由で feedback サーボ制御
- **dispatcher 拡張**: `X` (pan / yaw)、`Y` (tilt / pitch)、`V` (velocity)、`H` (head shake gesture)、`Q` (queue / quit) 等の frame key 追加
- **Mac 側 servo DSL**: `pc/stackchan-ble-client` 系の CLI に `servo pan=30 tilt=-15` 的なコマンド追加

これらは **仮説**。brainstorming で要件・優先順位・スコープ境界を整理する。

## ブレインストーミングで詰めたい論点

1. **対象サーボの仕様確認**
   - StackChan のサーボは **フィードバックサーボ 2 個** (CLAUDE.md より: 首振り 360° 連続回転 + チルト 90°)
   - 型番・プロトコル要調査。`../StackChan/firmware/main/hal/` の C++ 実装からピン配置・プロトコル特定
   - SCServo (FEETECH STS series) か MS S series か Dynamixel-like か未確認 — chiebukuro-mcp / StackChan firmware ソース要参照

2. **gem の構造**
   - 参考: 自作 `picoruby-mpu6886` (IMU、構造が近い) と `picoruby-vl53l0x`
   - PicoRuby の uart gem を使う？それとも独自 C 拡張？
   - 1 個の gem で 2 サーボ管理 vs サーボごとに instance ?

3. **dispatcher frame protocol 拡張**
   - 既存 4 key (F/M/S/C) との衝突回避
   - 新 key の名前付け (X/Y か Pan/Tilt か)
   - 値域 (-100..100 の正規化 vs 度数生)
   - velocity / acceleration の表現
   - ジェスチャー (頷く・首かしげ等) を frame protocol で表すか、Mac 側マクロにするか

4. **Mac 側 DSL / CLI**
   - `stackchan-ble-control` への subcommand 追加
   - `stackchan-notifier` 経由でも叩けるか
   - ジェスチャーのスクリプト化 (例 `nod`, `shake`, `look_at(x, y)`)

5. **HITL (人間視認) ゲートの組み込み**
   - 「サーボが期待通りに動いた」の自動検証は難しい (位置センサ feedback 読めれば検証可)
   - フィードバックサーボの内蔵 angle feedback を host 側に WriteAck で返す案？

6. **スコープ切り**
   - Phase B-1 (最小): 1 frame で 1 サーボ位置設定、HITL 視認
   - Phase B-2: 2 サーボ同時、velocity 制御
   - Phase B-3: ジェスチャーマクロ
   - どこまで Phase B に入れる？

## 参考リソース

- 自作 PicoRuby ドライバー gem (構造のお手本):
  - `/Users/bash/dev/src/github.com/bash0C7/picoruby-mpu6886` (IMU)
  - `/Users/bash/dev/src/github.com/bash0C7/picoruby-vl53l0x` (ToF distance)
- StackChan 公式 firmware (ピン配置・サーボプロトコル参照、書き込まない):
  - `../StackChan/firmware/main/hal/board/stackchan.cc`
  - `../StackChan/firmware/main/hal/drivers/` (servo driver C++)
- 既存 application.rb の Dispatcher 拡張ポイント: `mrbgems/picoruby-stackchan-protocol/examples/application.rb` の `StackchanApp::Dispatcher` クラス
- BLE wire format (frame protocol の互換性): memory `project_stackchan_wire_format`

## 次セッションでのトリガー文

user が以下のいずれかを言ったら brainstorming 起動:

- 「Phase B 始めて」
- 「servo の brainstorming やろう」
- 「Phase B のスコープ詰めよう」

`superpowers:brainstorming` skill を呼び、上記「論点」リストを土台に進める。brainstorming 後に `superpowers:writing-plans` で plan を起こし、その後 `superpowers:subagent-driven-development` で実装する従来パターン。

**brainstorming セッションで実装には入らないこと**。スコープ詰め → plan 作成 → 実装、の 3 段で。
