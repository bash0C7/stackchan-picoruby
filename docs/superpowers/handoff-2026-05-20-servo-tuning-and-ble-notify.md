# Handoff 2026-05-20: cold-boot self-test tuning + BLE notify next-up

## TL;DR for next session

1. **Cold-boot self-test を小さくして元位置復帰** — `application.rb` の自己診断 sweep を「ちょっと動く + ニュートラル復帰」に絞る。観測の目的は「servo 通信生きてる」を視認するだけで OK、現在の `Y=±1000 / P=200..800` は範囲外で「無茶な方向」を向く。
2. **次の実装は BLE 経由 notify** — protocol 層は完成済み (frame-delimited wire、device→client notify 1 frame/通知)。next: PC 側 `stackchan-notifier` から BLE 経由で `Y/P/V/T` frame を投げて servo を動かす経路を E2E 確認 → notify (LED/face) 経由のフックも整える。
3. **Repo state は clean** — 本 handoff 直前に下記すべて commit 済み (untracked 残らず)。

## Resume trigger

User 任意。「servo tuning 続き」「BLE notify 実装」「次やる」 等で開始。

## Phase B "servo bring-up" 結末 (2026-05-20 確定)

長らく **「servo が物理的に動かへん」** に詰まってた root cause は **UART pin swap**:

| | 公式 (`StackChan/firmware/main/hal/hal_servo.cpp:169`) | picoruby 旧 application.rb | 修正後 |
|--|--|--|--|
| TX | GPIO 6 (ESP32 → servo bus) | `txd_pin: 7` ✗ | `txd_pin: 6` ✓ |
| RX | GPIO 7 (servo bus → ESP32) | `rxd_pin: 6` ✗ | `rxd_pin: 7` ✓ |

公式 `SCSerial::begin(uart_num, baud_rate, tx_pin, rx_pin, buf_size)` のシグネチャ通り、call `_scs_bus.begin(UART_NUM_1, 1000000, 6, 7)` は **TX=6, RX=7**。旧 picoruby app は逆に書いてた → ESP32 が servo の TX 線を駆動してたので servo は何も受信せず、ESP32 は servo の RX 線 (high-Z) を listen してたので何も拾えず → 完全沈黙。

**修正後の cold-boot log で実証 (e42df29):**

```
[boot] enable_torque returns: y=true p=true
[boot] servo init OK
[diag id=1] PING tx=FF FF 01 02 01 FB raw_rx=FF FF 01 02 00 FC   ← ID=1 clean ACK
[diag id=2] PING tx=FF FF 02 02 01 FA raw_rx=FF FF 02 02 20 DB   ← ID=2 ACK (ERR=0x20 overload bit)
[boot] self-test servo: up Y=0 P=800 ... center Y=0 P=450
[boot] self-test servo read={"Y_actual" => 16896, "P_actual" => -11523}
```

物理的にも sweep で動くこと user 視認済み。ただし `Y_actual` / `P_actual` の値が範囲外 (SCSCL は 0-1023 unsigned position) で、commanded `Y=±1000 / P=200..800` も factory firmware の zero_pos calibration (`zero_pos_1=460 / zero_pos_2=620` per `hal_servo.cpp:173,182`) を経由してへんから「無茶な方向」を向く。これは tuning マターで、protocol 層は健全。

## やってほしい作業 (優先順)

### 1. Cold-boot self-test を縮小 + 元位置復帰

**Where:** `mrbgems/picoruby-stackchan-protocol/examples/application.rb` の `[boot] self-test servo:` block (現在 line 488 付近)。

**Why:** 観測目的は「servo 通信成立」を視認することだけ。`Y=±1000` は SCSCL の 0-1023 範囲外なので servo が無理に動こうとして overload bit (ERR=0x20 を id=2 PING で観測) を立てる原因にもなる。

**Spec:**
- factory firmware の zero_pos (`zero_pos_1 = 460`, `zero_pos_2 = 620`) を `Head` か `application.rb` で定数化
- self-test sweep は zero_pos からの **±100 程度の小幅** で 1 sweep (例: yaw +100, pitch +100, yaw -100, pitch -100, back to zero)
- 最後に必ず `zero_pos` (Y=460, P=620 の生 raw position) に戻す
- `Head#apply` の `Y` / `P` range mapping は本当はまだ未確定 — bring-up tuning と並行で `Head::YAW_RANGE` / `PITCH_RANGE` の意味付け (raw position 直 vs delta from zero) を決める

**TDD:** `test/scservo_test.rb` は SCS protocol v2 (ACK-aware) で書き直し必要。FakeUART に `clear_rx_buffer` / `flush` / `readpartial` no-op を実装すれば host で再現できる。今は壊れてるはず — まず修復 (Phase A の sub-skill: `superpowers:test-driven-development`)。

### 2. BLE 経由 servo 制御を E2E 検証

**Stack 現状:**
- Device 側: `Dispatcher#handle_head` (`application.rb:319`) → `Head#apply` → `SCServo#write_pos`。protocol 完成。frame `{"Y" => "0", "P" => "450", "T" => "600"}` で書ける。
- Wire: 1 frame = 1 BLE notify (frame-delimited)、ACK frame `.\n` + detail frame `<Y:val,P:val>\n` の 2 notify per servo command (`Client#send_frame` は drain 済み)。
- Notifier 側: `pc/stackchan-notifier/lib/stackchan_notifier/handlers/servo_handler.rb` 既存。

**Next:**
- `pc/stackchan-ble-client/exe/stackchan-ble-control` に `--servo Y:0,P:450,T:600` 風オプションあるはずなので、reset → BLE 接続 → servo frame 送信 → 動作観測の smoke loop を作る。`Rakefile` の `r2p2:ble_control_smoke` がベース、`r2p2:wait` task chain と組み合わせて 1 invocation 化できる。
- BLE 経由で servo が動いたら、notifier 経由 (DRb tuple write → handler → BLE → device) も verify。

### 3. 派生クリーンアップ (背景でやる、blocker 無し)

- `mrbgems/picoruby-scservo/test/scservo_test.rb` ホストテスト復活 (上記 TDD)。`test/fake_uart.rb` に `clear_rx_buffer` (no-op) / `flush` (no-op) / `readpartial(n)` (peek `pending_rx`) 追加。
- 古い docs に残った wrong pin 表記 (`docs/superpowers/specs/2026-05-19-phase-b-servo-design.md:52` "RXD=GPIO 6, TXD=GPIO 7" 等) は historical accurate 記録として fix-up コメント添付するか、別 doc に retraction note 入れる。`feedback_verify_handoff_assumptions_first` memory の対象。
- `docs/superpowers/specs/2026-05-14-stackchan-led-protocol-extension-design.md:689` の "UART1 GPIO 6/7" は方向書いてへんからセーフだが、再読時に誤読しない注記入れたい。

## Commit graph (この session の deliverable)

```
3674a7c feat(rake): add r2p2:wait[seconds] for chained single-process device flows
e42df29 fix(stackchan-protocol): swap UART TX/RX pins for servo bus + add raw PING diagnostic
2a72662 fix(scservo): align driver with FTServo_Arduino SCS protocol + add cold-boot self-test
091fca4 fix(ble-client): reset @last_detail_frame at start of send_frame
d122557 feat(ble-client): drain device detail frame after servo ACK
2ce7f78 chore(ble-client): clean up parse_ack test names + dedupe
f530add feat(ble-client): parse_ack accepts frame string
f90ed2a feat(protocol): device-side frame queue (Array) replaces byte ACK queue
92f1642 feat(protocol): dispatcher emits complete frames per write
```

## 観測ポイント / 既知の noise

- **id=2 (pitch) PING で ERR=0x20 (overload bit)** が立ってた。原因不明 — factory firmware で動くんだから hardware 故障ではない。Tuning 後にも残るなら `enable_torque` 前に `clear_error` 系 op が要るかも。
- `Y_actual=16896 / P_actual=-11523` は **commanded position が範囲外** + servo が motion 中に読まれたため (`Machine.delay_ms(800)` だが SCSCL の Time フィールドは `10ms 単位` 仕様の可能性大、`T=600` = 6 秒 motion → 800ms 経過時点ではまだ大幅 mid-motion)。tuning で Time の単位 / range を実機 calibrate。
- **chain rake は 25s wait 必須 (post-wipe)** — empirical。15s では USB-CDC renum + R2P2 shell ready が間に合わず `picomodem cursor_replies=0`。`Rakefile` task chain で `r2p2:wait[25]` を必ず噛ます。

## Skills / patterns 推奨

- `superpowers:test-driven-development` — host scservo_test 修復は TDD で
- `superpowers:brainstorming` → `superpowers:writing-plans` — BLE notify E2E は spec 詰めてから plan
- `superpowers:subagent-driven-development` — plan 実行は subagent 駆動
- `stackchan-device-iterate` / `-cold-recovery` skill 群 — device cycle は skill 経由 (rake 直叩き禁止、CLAUDE.md project rule)
- skill 群を chain rake (`rake A wait[N] B`) に統合する作業は Phase B 残課題に積んでもよい — ただし `r2p2:wait` task は既に 25s で動作確認済みなので、`stackchan-device-cold-recovery.md` の中身を「wipe → wait[25] → upload → wait[2] → reset の 1 rake 呼び出し」へ書き換える小タスクとして残ってる。

## 注意

- application.rb 編集後は **picoruby-scservo が firmware-bundled mrbgem ではなく**、scservo 本体は今 firmware に焼き込み済み。application.rb 修正は `rake r2p2:upload_appmrb` のみで反映する (firmware rebuild 不要)。
- ただし scservo.rb (`mrbgems/picoruby-scservo/mrblib/scservo.rb`) を変更したら firmware rebuild + flash → `rake r2p2:build_flash` (5-10 分) + 25s wait + upload_appmrb 必要。
- bring-up debug log は `/tmp/stackchan-picoruby-debug/*.log` に集約 (CLAUDE.md ルール)。直近: `boot-pinfix.log` (修正後の動作確認)、`boot-diag.log` (修正前の silent RX 証拠)。
