# Handoff 2026-05-21: cold-boot redesign + BLE normalized protocol

## TL;DR for next session

User redirected work mid-session 2026-05-20 → 旧 handoff `handoff-2026-05-20-servo-tuning-and-ble-notify.md` の Task 4 (calibration) は **新 design に supersede** された。read_pos の deep debug (Task 2 残務) は **新 design では非依存** なので deferred。

新 design は brainstorming で Section 1-3 まで presented・user 同意待ちで一時中断。次セッションはここから再開。

## Resume trigger

User 任意。「cold-boot redesign 続き」「新 design 再開」「次やる」等。

## 完了した design 決定 (Q&A で確定済)

| # | 設計ポイント | 決定 |
|--:|---|---|
| 1 | 初期位置の定義 | calibrated 正面向き (固定値)、電源投入時に人間が手でアライン |
| 2 | BLE notify 単位 | 正規化 (-100..+100) |
| 3 | torque-off 起動条件 | 明示的な BLE コマンド (自動切断検知はしない) |
| 4 | `<T:on>` 後の self-test | 走らせない。別途明示 `<S:test>` で実行 |
| 5 | RANGE 定数 (初期値) | yaw=±50 raw / pitch=±30 raw (iterative で拡張、まず狭めで) |
| 6 | torque-off 中の LCD | Face::Sleeping (閉じ眼) 専用 face state |
| 7 | raw frame `<Y:460>` 互換 | **廃止**、normalized のみ |

## Brainstorming で残ってる作業

Section 1-3 までは presented (cold-boot flow / BLE frame protocol / normalized→raw mapping)。残りの section:

1. **Section 4: Face state 追加** — Face::Sleeping の geometry 設計 (閉じ眼のシンプルな golden、HITL approval 不要レベルで OK か HITL いるか)
2. **Section 5: Test 戦略** — host test (FakeUART で frame parser test) + device test (BLE smoke で `<T:on>` → `<Y:0,P:0>` → `<T:off>` flow)
3. **Section 6: Migration** — 既存 raw frame format を使ってる test / docs / client (`pc/stackchan-ble-client/exe/stackchan-ble-control`) の更新 plan
4. **Section 7: 完了基準 / DoD** — 何が揃ったら新 design 完成と呼ぶか

それぞれ短くまとめて user approval 取って、spec doc に落とす → plan に進む。

## Spec doc 作成先

`docs/superpowers/specs/2026-05-21-cold-boot-torque-off-and-normalized-protocol-design.md`

## 想定 implementation 概要 (spec 確定後の参考)

### application.rb cold-boot 変更
- 現状: AXP/AW/PY32/LCD init → Face::Neutral → sleep_ms 3000 → Head init (**enable_torque で torque ON + self-test 実行**) → BLE start → Dispatcher loop
- 新: AXP/AW/PY32/LCD init → **Face::Sleeping** → sleep_ms 3000 → Head init (**enable_torque 呼ばず、torque OFF のまま**) → BLE start → Dispatcher loop (servo 操作 frame 受け取り待ち)

### Dispatcher 新ハンドラ
- `<T:on>`: `@head.enable_torque(true, true)` (yaw + pitch) → Face::Neutral 描画 → ACK
- `<T:off>`: `@head.enable_torque(false, false)` → Face::Sleeping 描画 → ACK
- `<S:test>`: yaw ±10 raw 微小 sweep → ゼロ復帰 → ACK + detail
- `<Y:N,P:M,T:tt>`: -100<=N,M<=100 check → 範囲外 ERROR、範囲内なら raw 変換 → `@head.apply` → ACK + detail
  - `raw_y = SERVO_YAW_ZERO + (N * YAW_RANGE / 100)`
  - `raw_p = SERVO_PITCH_ZERO + (M * PITCH_RANGE / 100)`

### Head 変更点
- 既存 `apply` は raw 値受け取り維持 (`@dispatcher` で正規化変換済みの raw を渡す)
- `enable_torque(yaw_on, pitch_on)` メソッド既存ならそのまま、無ければ追加

### 新定数 (Head か StackchanApp に)
```ruby
SERVO_YAW_ZERO   = 460   # 既存
SERVO_PITCH_ZERO = 620   # 既存 — 後でキャリブで修正の可能性
YAW_RANGE        = 50    # ±100 normalized → ±50 raw (iterative)
PITCH_RANGE      = 30    # ±100 normalized → ±30 raw (iterative)
```

### Face::Sleeping (新)
- 既存 Face::Neutral.geometry を base に、眼を「線」(横一線) で描く程度の差分
- golden SHA 必要だが「閉じ眼」は seculity 視覚承認低 (= HITL skip 可能性高)、ただし `stackchan-device-face-verify` で golden lock するのが安全

## Session 2 (2026-05-20) のコミット graph

```
1d28632 docs(handoff): mark Task 4 superseded by new cold-boot+normalized-protocol design
102ba98 docs(handoff): session 2 close — read_pos unresolved, next-step plan
07be894 fix(scservo): make drain_echo non-blocking to avoid consuming servo response
19a9585 fix(scservo): drain TX echo before reading servo response on half-duplex bus
8310fcf docs(handoff): mark Task1/2/3 complete + add Task4 servo calibration
154db90 fix(servo): shrink self-test to ±30/3-step + add ble_servo_smoke rake task
80470a4 fix(docs+rake): correct UART pin docs + add ble_servo_smoke task
ebb70ef fix(test): repair host test suite after SCS protocol v2 + servo tuning
```

## read_pos の継続課題 (新 design 後の独立タスク)

新 design は read_pos 非依存だが、将来的に「servo 実位置を AI 側に渡す」「位置 feedback で error 検出」等が欲しくなったら必要。現状の状態:

| アプローチ | commit | 結果 |
|---|---|---|
| blocking drain_echo (READ_TIMEOUT_MS poll) | 19a9585 | timeout 100ms × バイト数で response window 食い潰し → `servo_timeout` |
| non-blocking drain_echo (read-as-available) | 07be894 | 同じく `servo_timeout` — drain は echo を消費せず、check_head も response を見つけられない |

仮説の優先順位:
1. **ESP32-S3 UART は TX→RX echo しない** (echo bytes は最初から無い) — drain_echo は no-op、check_head が timeout する別原因がある
2. servo response が register 0x38 (PRESENT_POS_L) に来てない (SCS series 違いで register 違う?) — `../StackChan/firmware/main/hal/drivers/FTServo_Arduino/SCSCL.h` を read して address 再確認
3. clear_rx_buffer 自体が PicoRuby UART で動いてない / lazy

次の手: scservo.rb に raw byte dump method 追加 → BLE 経由で 1 回呼んで boot.log 取る → bytes 見て原因特定。

## 注意

- 新 design 実装は scservo gem 自体は触らない見込み (UART 層変更不要、application.rb と Dispatcher のみ)。だが `enable_torque` が `gen_write` → `ack` 経路に依存してて、`ack` が drain_echo の影響で常に false 返してる可能性あり。実機で `<T:on>`/`<T:off>` の torque 切替が反映されるか実機テスト必須
- Face::Sleeping 追加で `mrbgems/picoruby-stackchan-protocol/examples/application.rb` の Face DSL section が増える。`docs/superpowers/specs/2026-05-19-phase-a-faces-design.md` の design 方針と整合性確認
- `pc/stackchan-ble-client/exe/stackchan-ble-control` の CLI option も改修 (`--yaw 460` → `--yaw 0` で 正面 になる、option default 変更)

## Skills 推奨

- `superpowers:brainstorming` — Section 4-7 の続きはこれで再開
- `superpowers:writing-plans` — spec 確定後
- `superpowers:test-driven-development` — Dispatcher の新ハンドラはまず host test (FakeUART) で
- `superpowers:subagent-driven-development` — plan 実行
- `stackchan-device-iterate` — 実機検証 cycle
- `stackchan-device-build-flash` — application.rb のみ変更なら不要、scservo 触る場合のみ
