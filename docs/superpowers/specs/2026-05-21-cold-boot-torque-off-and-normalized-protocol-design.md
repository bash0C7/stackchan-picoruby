# Cold-boot Torque-Off + Normalized Protocol Design

**Date:** 2026-05-21
**Supersedes:** Phase B "Servo Tuning" task 4 (calibration) in `handoff-2026-05-20-servo-tuning-and-ble-notify.md`
**Continues from:** `handoff-2026-05-21-cold-boot-redesign.md` Section 1-3 (handoff で確定済み) + brainstorming Section 4-7 (本 spec で詰めた)

## 動機

現状の cold-boot シーケンス (Phase B 完了時点) は以下:

1. cold-boot init → Head init で **`enable_torque(true,true)`** → cold-boot self-test (±30 raw nudge) → BLE start
2. dispatcher が `<Y:N,P:M,T:tt,V:vv>` の raw 値ベース servo frame を受け取る
3. detail frame `<Y_actual:N,P_actual:M>` を `read_pos` で取得 → 但し `read_pos` は servo_timeout 未解決

問題:
- 電源投入直後に servo torque ON + self-test が走るので、**個体ごとのサーボ raw zero ズレ** で「正面向き」が物理的に不正確 (calibrated 正面 から逸脱) — でも自動補正手段がない
- raw 値 (`Y:460` 等) は AI/operator 側の concept (「左 50%」「正面」) と乖離、CLI / docs で説明コスト高
- raw frame は SCS register encoding (上位 bit sign) と直結し、向きの semantics が不透明

新 design の主眼: **operator は「StackChan の左に 50%」「正面」「上を向く」を自然な語彙で送れる** ことと、**cold-boot で人間が手で物理的に正面アラインできる** こと。

## Section 1: cold-boot flow

### 旧 flow
```
AXP/AW/PY32/LCD init → Face::Neutral → sleep_ms 3000
→ Head init (enable_torque で torque ON + self-test 実行)
→ BLE start → Dispatcher loop
```

### 新 flow
```
AXP/AW/PY32/LCD init → Face::Closed → sleep_ms 3000
→ Head init (enable_torque 呼ばず、torque OFF のまま) → BLE start
→ Dispatcher loop (servo 操作 frame 受け取り待ち)
```

### 確定事項 (handoff Q&A)

| # | 設計ポイント | 決定 |
|--:|---|---|
| 1 | 初期位置の定義 | calibrated 正面向き (固定値)、電源投入時に **人間が手でアライン** |
| 3 | torque-off 起動条件 | **明示的な BLE コマンド** (自動切断検知はしない) |
| 4 | `<torque:on>` 後の self-test | **走らせない** (別途明示 `<selftest:run>` で実行) |
| 6 | torque-off 中の LCD | **Face::Closed** (旧 design の Face::Sleeping は採用せず) |

注: handoff Q2 (BLE notify 単位 = 正規化 -100..+100) と Q5 (raw RANGE) と Q7 (raw 廃止) は brainstorming Section 5-6 で **direction-key + magnitude (0..100) 型に refine**。Section 2 (frame protocol) と Section 3 (mapping) を一次資料とする。

操作シナリオ:
1. 電源投入 → cold-boot 完走 → LCD に Face::Closed (閉じ眼) 描画、サーボ torque OFF
2. 人間が StackChan の頭部を **手で物理的に正面に向ける**
3. PC / 操作端から `<torque:on>` 送信 → torque ON、Face::Neutral 描画、ACK 返る
4. 以降 `<YL:N,PU:M,T:tt>` 等で servo 制御、`<F:n>` 等で face 切替
5. 終了時 `<torque:off>` → torque OFF、Face::Closed、ACK

## Section 2: BLE frame protocol final spec

### Frame syntax 全 key (post-redesign)

| key | 値 | 用途 | sub-system |
|---|---|---|---|
| `F` | `0..5` | face index (Phase A 維持) | face |
| `L` | `1` | LED command start flag (Phase A 維持) | LED |
| `R`, `G`, `B` | `0..255` | LED RGB 値 (Phase A 維持) | LED |
| `S` | `L`/`R`/`B` | LED side (Phase A 維持、wire-side は ble-client が反転吸収) | LED |
| `M` | `s`/`b`/`p`/`o` | LED mode (Phase A 維持) | LED |
| `YL` | `0..100` | yaw 方向 = StackChan の **左**、magnitude | servo |
| `YR` | `0..100` | yaw 方向 = StackChan の **右**、magnitude | servo |
| `PU` | `0..100` | pitch 方向 = **上**、magnitude (Down 不可、`PU:0` で中央) | servo |
| `T` | ms | servo 動作 time_ms (Phase B 維持) | servo |
| `V` | int | servo velocity (Phase B 維持) | servo |
| `torque` | `on` / `off` | torque enable/disable (full word key、rare event) | system |
| `selftest` | `run` | yaw ±10 raw 微小 sweep self-test (rare event) | system |

### 衝突回避ルール

- **yaw L/R は同一 frame に同時指定不可 (排他)**。違反時は **`YL` 優先**、`YR` は ignore (predictable な動作)
- **pitch Down は protocol 上不可**。下向きが必要なら `<torque:off>` で物理的に手で
- **LED `L:1` と servo `YL/YR/PU` は別 key** なので同一 frame combo 可能。`<F:2,YL:50,PU:30,L:1,R:255,G:0,B:0,M:p,S:R,T:500>` 型 OK
- 範囲外 (例 `YL:150`) は **ERROR ACK (`?\n`)**

### Naming convention

- **頻繁な命令は short key** (F/L/R/G/B/S/M/YL/YR/PU/T/V)
- **rare event (cold-boot / teardown) は full word key** (`torque`, `selftest`)

### Frame example

| Frame | 意味 |
|---|---|
| `<torque:on>\n` | torque ON、Face::Neutral 描画 |
| `<torque:off>\n` | torque OFF、Face::Closed 描画 |
| `<YL:0,PU:0>\n` | 正面に戻る (yaw 中央 + pitch 中央) |
| `<YL:50,T:500>\n` | yaw を左 50% に 500ms かけて移動 |
| `<YR:30,PU:80,V:60>\n` | yaw 右 30%、pitch 上 80% を velocity 60 で移動 |
| `<selftest:run>\n` | yaw ±10 raw 微小 sweep |
| `<F:2,YL:50,L:1,R:255,G:0,B:0,M:p,S:R,T:500>\n` | face Joy + servo yaw 左 50% + LED 右側赤 breathing を 500ms で combo |

### Response

- ACK 成功: `.\n`
- ERROR (範囲外 / 不明 key / etc): `?\n`
- Detail (servo 指令時のみ追加): Section 5 で規定

## Section 3: normalized magnitude → raw mapping

確定事項 (handoff Q5):

- yaw RANGE = ±50 raw (`SERVO_YAW_ZERO` ± 50)
- pitch RANGE = ±30 raw (`SERVO_PITCH_ZERO` ± 30)

normalized → raw 変換式 (Dispatcher 側で適用、Head は raw を受け取る):

```ruby
SERVO_YAW_ZERO   = 460   # 既存
SERVO_PITCH_ZERO = 620   # 既存
YAW_RANGE_RAW    = 50    # iterative、まず狭めで
PITCH_RANGE_RAW  = 30    # iterative

# YL key の場合 (StackChan の左)
raw_y = SERVO_YAW_ZERO + (magnitude * YAW_RANGE_RAW / 100)

# YR key の場合 (StackChan の右)
raw_y = SERVO_YAW_ZERO - (magnitude * YAW_RANGE_RAW / 100)

# PU key の場合 (上向き)
raw_p = SERVO_PITCH_ZERO + (magnitude * PITCH_RANGE_RAW / 100)
```

注意: 「YL が物理的に左 (operator 視点で右)」「PU が物理的に上」になる raw sign は実機で確認、ズレてたら `+` / `-` を Head 内で吸収。RANGE は iterative に拡大予定 (まず狭めで安全側スタート)。

## Section 4: Face::Closed 仕様変更

### 現状

`application.rb:170-191` の `Face::Closed` は **blink animation 内部用** で、`draw` メソッドは `clear_eye_region + draw_eyes` (eye-only redraw) のみ。背景 fill しない、口描画しない、`FACE_TABLE` 未登録、`face_golden_test` 明示 exclude。

### 新仕様

`Face::Closed#draw` を **「full-screen background fill + 閉じ眼 2 本 (口無し)」** に変更:

```ruby
class Closed < Base
  def draw(display)
    display.fill(BACKGROUND_COLOR)
    draw_eyes(display)   # 閉じ眼 (既存 horizontal line) を描く
    # 口は描かない
  end

  def draw_eyes(display)
    # 既存の Closed の closed-eye 描画ロジックそのまま
  end
end
```

blink animation 用には別メソッド (例 `Base#redraw_eyes_closed(display)`) を切り出し、application.rb の blink 呼び出し点を新メソッドに更新。

### HITL approval

- **HITL 顔承認 skip** (visually trivial、黒背景 + 線 2 本のみ)
- `face_golden_test` に `closed` を追加して `spec/golden/face_closed.sha256` を新規 lock (回帰防止)
- `stackchan-device-face-verify` skill (BLE 経由 LCD 描画 + golden SHA assert) は走らせる

### FACE_TABLE への登録

- **登録しない**。Face::Closed は **Dispatcher が `<torque:off>` 内部で直接呼ぶ** だけで、wire-protocol で `<F:n>` 経由では呼べない (`<F:6>` は ERROR)

## Section 5: test 戦略

### E2E (絶対位置精度) PASS 基準

**HITL 5 位置目視**を必須 PASS 基準にする:

| # | 指令 frame | 期待物理動作 |
|--:|---|---|
| 1 | `<YL:0,PU:0,T:500>` | 正面 (中央復帰) |
| 2 | `<YR:100,T:500>` | 右端 (StackChan の右、operator から見て左) |
| 3 | `<YL:100,T:500>` | 左端 (StackChan の左、operator から見て右) |
| 4 | `<PU:100,T:500>` | 真上 |
| 5 | `<YL:0,PU:0,T:500>` | 正面復帰 |

ツールは rake task + checklist 形式、人間が Y/N 返す。実機目視で 1 回でも N なら redesign blocker。

### Host test scope

| Test file | 更新内容 |
|---|---|
| `mrbgems/picoruby-stackchan-protocol/test/frame_parser_test.rb` | **変更なし** (frame format `<key:value,...>` 不変) |
| `mrbgems/picoruby-stackchan-protocol/test/test_dispatcher_frame_contract.rb` | 新 handler test 追加 (`<torque:on>` / `<torque:off>` / `<selftest:run>` / normalized `<YL:N,PU:M,T:tt>` / 範囲外 ERROR / `<YL:N,YR:M>` 衝突時 YL 優先 / fallback unknown) |
| `test/dispatcher_servo_test.rb` | normalized → raw 変換 math を host test、actual=unknown 時 detail も網羅 |
| `test/dispatcher_test.rb` | LED + face combo 系 test 維持、新 servo key combo 追加 |
| `test/head_test.rb` | Head#apply は raw 値受け取り維持なので **変更なし** |
| `test/face_test.rb` | Face::Closed 新 draw (full fill) 検証、blink 用 eye-only redraw method の検証 |
| `test/face_golden_test.rb` | `FACE_CASES` に `closed` 追加、`spec/golden/face_closed.sha256` 新規 lock |
| `test/scservo_test.rb` | read_pos retry 機構 (Section 5 後段) の test 追加 |
| `test/ruby_class_extract_test.rb` | 変更なし |

raw frame 互換は廃止確定 (handoff Q7) なので、**既存 raw 前提 test は normalized に全面書き換え、raw 値 test は削除** (Head#apply の raw 受け取り単体 test は除く)。

### Detail frame (servo actual)

read_pos を新 design では scope に含める (level 3)。retry policy: N 回試行 (N は実装フェーズで決定、推奨 N=3、各 timeout 50ms)。

| 状況 | detail frame |
|---|---|
| read_pos 成功 (yaw 動いた結果 = 左) | `<YL_actual:50,PU_actual:30>\n` |
| read_pos 成功 (yaw 動いた結果 = 右) | `<YR_actual:50,PU_actual:30>\n` |
| read_pos 成功 (yaw 中央) | `<YL_actual:0,PU_actual:0>\n` (方向 key は YL/PU で固定) |
| read_pos 失敗 (N 回 retry 全敗) | `<YL_actual:unknown,PU_actual:unknown>\n` |
| servo 未初期化 (@head=nil) | `<ERROR:servo_unavailable>\n` |

**`unknown` は単なる fallback ではなく「operator に手キャリブ介入が必要」の protocol-level signal**。PC client (`stackchan-ble-control`) は unknown を見たら warning 出力 + exit code (推奨 EXIT_CALIBRATION_NEEDED, 値は実装フェーズで決定) で operator に伝える責務を負う。

### read_pos deep debug

handoff §read_pos の継続課題を本 redesign の scope に含める。仮説 3 つを優先順で潰す bisect session を implementation plan に組み込む:

1. **ESP32-S3 UART が TX→RX echo しない仮説** — drain_echo 前提が違う可能性。scservo に raw byte dump method 追加 → BLE 経由で 1 回呼んで boot.log 取得 → echo 有無を仕様照合
2. **register address ズレ仮説** — PRESENT_POS_L が 0x38 で正しいか、`../StackChan/firmware/main/hal/drivers/FTServo_Arduino/SCSCL.h` で再確認
3. **clear_rx_buffer 不動仮説** — PicoRuby UART の clear_rx_buffer が実際に flush するか実機検証

成功 → detail に数値 actual を返す実装に進む。失敗 → fallback `unknown` で完成 (本 PR は merge 可能、deep debug は別 spec/PR で継続)。

## Section 6: migration

### 更新範囲 (raw frame 言及 sweep)

| Path | 更新内容 |
|---|---|
| `mrbgems/picoruby-stackchan-protocol/examples/application.rb` | cold-boot シーケンス書き換え (Face::Closed → sleep_ms 3000 → enable_torque 呼ばず → BLE start)、Dispatcher の `handle_head` / `handle_torque` / `handle_selftest` 実装、Face::Closed#draw を full-fill に、blink eye-only redraw を別 method 化 |
| `pc/stackchan-ble-client/lib/stackchan_ble_client/frame_codec.rb` | `encode_head` を direction-key 出力に書き換え (`yaw_left:`, `yaw_right:`, `pitch_up:` kwargs)、`encode_torque(on:)`, `encode_selftest` を追加 |
| `pc/stackchan-ble-client/lib/stackchan_ble_client/send_builder.rb` | `#head(yaw_left: nil, yaw_right: nil, pitch_up: nil, time_ms: nil, velocity: nil)` API に書き換え、`#torque(on:)` / `#selftest` を追加 |
| `pc/stackchan-ble-client/exe/stackchan-ble-control` | CLI option `--yaw V --pitch V` を `--yaw-left N` / `--yaw-right N` / `--pitch-up N` に変更、default 0、`torque` / `selftest` サブコマンド追加、`unknown` 検出時の操作員 warning + exit code |
| `pc/stackchan-ble-client/test/*` | send_builder / frame_codec / client_test を新 API に書き換え |
| `Rakefile` | `r2p2:ble_servo_smoke` 等 task を新 syntax に、新 task `r2p2:ble_torque_smoke` / `r2p2:ble_calibration_check` (HITL 5 位置) 追加検討 |
| `docs/superpowers/specs/2026-05-14-stackchan-protocol-design.md` | servo section を direction-key syntax に書き換え |
| `docs/superpowers/specs/2026-05-19-phase-b-servo-design.md` | "raw frame" 言及箇所に "**superseded by 2026-05-21**" marker 追加 (履歴 doc として保存) |
| `CLAUDE.md` | 「BLE servo control = direction-key + magnitude」を 1 セクションで明文化 |

raw frame は host PR sweep 後に `grep -rn 'Y:[0-9]' / 'P:[0-9]' / '--yaw [0-9]'` で残骸なきこと確認。

### Migration 戦略

- **後方互換なし** (raw frame 廃止確定、移行期間設けず)
- 全 caller / doc / test を 1 PR で normalized 化
- 既存 raw 値 caller を grep で全列挙 → implementation plan で task 化

## Section 7: Definition of Done

| # | 項目 | 検証手段 |
|--:|---|---|
| 1 | cold-boot で torque OFF 起動 + Face::Closed 描画 | `/stackchan-device-iterate` + boot.log |
| 2 | `<torque:on>` で torque ON + Face::Neutral + ACK | BLE smoke (新 rake task) |
| 3 | `<torque:off>` で torque OFF + Face::Closed + ACK | BLE smoke |
| 4 | `<selftest:run>` で yaw ±10 raw sweep + ACK + detail | BLE smoke |
| 5 | `<YL:N,PU:M,T:tt>` 等で ACK + detail (期待 syntax) | BLE smoke |
| 6 | 範囲外 (例 `YL:150`) で ERROR ACK | host test + BLE smoke |
| 7 | `<YL:50,YR:30>` 衝突時に YL 優先 | host test |
| 8 | LED + servo + face combo (`<F:2,YL:50,L:1,R:255,...>`) 同時動作 | BLE smoke |
| 9 | read_pos deep debug の outcome decide: 成功 → 数値 actual / 失敗 → `unknown` fallback + operator 手キャリブ手順 docs | 実機 + boot.log |
| 10 | HITL 5 位置目視 (正面 / yaw 左端 / yaw 右端 / pitch 中央 / pitch 上端) で物理動作 OK | 人間 Y/N |
| 11 | host test 全 PASS + `face_closed.sha256` 新規 lock + Phase A 6 face SHA 不変 | `rake test` |
| 12 | 既存 raw frame 言及 0 (`grep -rn 'Y:[0-9]\|P:[0-9]\|--yaw [0-9]\|--pitch [0-9]'`、除 history doc) | grep |
| 13 | `stackchan-ble-control` 新 CLI 動作 (`--yaw-left N` / `--yaw-right N` / `--pitch-up N` / `torque` / `selftest`) | rake task + 人間実行 |

13 項全て必須。1 つでも欠けたら本 redesign の PR は merge しない。

## Out of scope

- **PRESENT_LOAD / PRESENT_MOVING (level 2 read)** — read_pos と同経路、本 PR では未試験。read_pos 解決後の future evolution で追加検討
- **detail frame 完全自動化** — HITL 5 位置目視は本 PR では人間判定 (numerical assertion は read_pos 解決時のみ available)
- **calibration の persistent storage** — 個体ごとの raw zero 補正値を flash に保存する話は別 spec
- **Bluetooth pairing / authentication** — 現状 open NUS、本 PR では変更なし

## 関連 memory (claude auto-memory、`~/.claude/projects/<repo>/memory/` 配下)

- `feedback-servo-absolute-pos-is-core` — stackchan の本質は BLE 経由絶対位置制御
- `project-actual-unknown-signals-manual-cal` — `unknown` は operator 介入 signal
- `project_ble_phase3_btstack_starve_finding` — cold-boot 後 sleep_ms 3000 必須 (本 redesign でも維持)
- `project_design_d_app_side_and_skills` — Face/Dispatcher は application.rb、FrameParser のみ firmware
