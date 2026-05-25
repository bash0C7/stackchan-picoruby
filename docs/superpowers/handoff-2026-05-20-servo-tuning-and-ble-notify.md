# Handoff 2026-05-20: cold-boot self-test tuning + BLE notify next-up

> **更新 2026-05-20 (session 2 後半):** user 指示で方向転換。Task 4 (calibration) は新 design (cold-boot torque-off + normalized -100..+100 protocol + 明示 `<T:on>`/`<T:off>`/`<S:test>` BLE frame) に **supersede された**。Task 2 の read_pos は新 design では依存しないので **deferred**。新 design spec/plan を別 doc で策定中。
>
> **更新 2026-05-20 (session 2 前半):** Task 1/3 完了、Task 2 は write_pos 確認済 / read_pos は未解決 (次セッション継続)。Task 4 (servo range calibration) 新規追加 (人間目視必須)。

## TL;DR for next session

1. ~~Cold-boot self-test を小さくして元位置復帰~~ **DONE (154db90)** — ±30/3-step/T=50
2. **BLE 経由 servo 制御 E2E 検証 — write_pos PASS / read_pos 未解決**
   - write_pos: 実機物理動作確認済 (user「動いた」、`--pitch 512` で可視動作)
   - read_pos: drain_echo blocking → non-blocking と 2 段階で deploy したが `servo_timeout` のまま。仮説: ESP32-S3 UART が TX→RX エコーを行わず、別経路で stale bytes が混入してる。次セッションで raw byte dump 取って分析する必要あり (19a9585, 07be894)
3. ~~派生クリーンアップ~~ **DONE** — scservo_test 53/53 PASS、doc pin 表記修正
4. **NEW: Servo range キャリブレーション** — `SERVO_PITCH_ZERO=620` が実機で「真上向き」と判明。正確な正面向きポジション / 可動範囲を人間目視で calibrate する。

## Resume trigger

User 任意。「servo tuning 続き」「read_pos デバッグ」「キャリブレーション」「次やる」 等で開始。

## read_pos debugging next steps

Session 2 で試した方策と結果:

| アプローチ | commit | 結果 |
|---|---|---|
| blocking drain_echo (READ_TIMEOUT_MS poll) | 19a9585 | timeout 100ms × バイト数で response window 食い潰し → `servo_timeout` |
| non-blocking drain_echo (read-as-available) | 07be894 | 同じく `servo_timeout` — drain は echo を消費せず、check_head も response を見つけられない |

仮説の優先順位:
1. **ESP32-S3 UART は TX→RX echo しない** (echo bytes は最初から無い) — drain_echo は no-op、check_head が timeout する別原因がある
2. servo response が register 0x38 (PRESENT_POS_L) に来てない (SCS series 違いで register 違う?) — `../StackChan/firmware/main/hal/drivers/FTServo_Arduino/SCSCL.h` を read して address 再確認
3. clear_rx_buffer 自体が PicoRuby UART で動いてない / lazy

次セッション最初のステップ: scservo.rb に `read_raw_bytes` デバッグ method 足して、`read_pos` 内で受信した生バイトを `puts` で吐く → BLE 経由で 1 回呼んで boot.log 取る → bytes を見て原因特定。

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

### 4. NEW: Servo range キャリブレーション (人間目視必須)

**経緯:** 2026-05-20 session 2 で `SERVO_PITCH_ZERO=620` を命令したところ servo が「真上向き」で止まることを user が視認。`--pitch 512` に変更したら servo が可視的に動いた (BLE E2E PASS 確認)。つまり:

- `P=620` = 真上方向 (forward ではない)
- `P=512` = より forward に近い (推定)
- `SERVO_YAW_ZERO=460`, `SERVO_PITCH_ZERO=620` の定数は実機と不一致

**作業内容:**
1. pitch sweep: `--pitch` を 400 / 450 / 500 / 512 / 550 / 600 / 620 と変化させながら BLE コマンド発行、各位置で human が「正面向き/上向き/下向き」を記録
2. yaw sweep: `--yaw` を 350 / 400 / 430 / 460 / 490 / 520 / 560 で同様に記録 (460 が正面向きか確認)
3. 結果から `SERVO_YAW_ZERO` / `SERVO_PITCH_ZERO` を修正
4. 自己テスト定数と BLE smoke task のデフォルト値も更新

**コマンド例:**
```bash
# pitch 単体チェック (yaw は固定)
cd pc/stackchan-ble-client
bundle exec exe/stackchan-ble-control --name-prefix StackChan-PicoRuby --yaw 460 --pitch 512 --time 50 servo
```

**注:** read_pos は現在ハーフデュプレックスエコー問題でゴミ値を返す。位置確認は人間目視のみで行う。

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

session 2 (2026-05-20) 追加分:
```
154db90 fix(servo): shrink self-test to ±30/3-step + add ble_servo_smoke rake task
ebb70ef fix(servo): add SERVO_*_ZERO constants + replace hardcoded positions
c7ee44d fix(scservo/test): revive scservo_test 52/52 PASS + fix dispatcher ACK frames
```

session 1 (2026-05-20) 分:
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
