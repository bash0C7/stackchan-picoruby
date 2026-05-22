# Handoff: BLE chain-flush + SDK regex fix — 完了 + 次フェーズ HITL calibration

Date: 2026-05-22 (前 handoff `2026-05-22-scservo-scscl-byte-order-fix-complete-handoff.md` の同日後続)
Branch: `feat/servo-tuning-and-test-fix` @ `d5dfb5b`
Repo: `/Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby`

## 状態語

**完了** — autonomous debug session で 2 個の bug を発見・fix・実機実証・commit
済。device は clean 版 application.rb で cold-boot 済、torque OFF + Face::Closed
idle + BLE adv 中。次 session は HITL calibration 起点で進める。

## 今 session の成果

| Item | 値 |
|---|---|
| Smoke 4 件 (face/read:pos/selftest/servo round-trip) | 全 OK |
| SDK bug fix (servo_frame? regex) | commit `614d0e1` |
| device bug fix (chain CAN_SEND_NOW) | commit `d5dfb5b` |
| host test | 70 / 124 / 0 / 0 / 5 omissions (unchanged baseline) |
| 実機実測 6-frame flush | **551ms** (avg 110ms/frame、fix なしは ~6 秒) |
| read:pos 再現性 | yaw_raw=472→459 (selftest 後)、pitch_raw=630 (3 連続同値) |

## Bug #1: SDK `servo_frame?` regex (commit 614d0e1)

### Symptom
`pc/stackchan-ble-client` の CLI で `servo --yaw-left 0` を投げると
`[detail] nil` が返り、detail frame が取りこぼされる (drain されず subscription
queue に残る → 次 frame で誤動作の温床)。

### Root cause
`client.rb:102` の `servo_frame?` regex `/[YPVT]:/` は単一文字キー + `:` を見る
古い protocol 前提。現 protocol の 2-char キー (YL/YR/PU) は match しない。
`YL:0` だと "Y" の次が "L" で `:` じゃないため false → detail 待ち skip。

T/V modifier 含む frame (`<YL:0,T:250>`) は `T:` 部分で偶然 match していたため
host test の SendBuilder fixture では検出されず regression として温存されてた。

### Fix
- regex を `(?:YL|YR|PU):` に変更 (device-side `application.rb:320`
  `servo_present = frame.key?("YL")|..|("PU")` の集合を mirror)
- test fixture 2 箇所 (`client_test.rb`, `frame_codec_test.rb`) を新 protocol
  に refresh
- regression test 追加: `test_axis_only_servo_frame_without_time_or_velocity_drains_detail`
  が `s.head(yaw_left: 0)` (T/V 無し axis only) を drive して detail drain を assert

### 検証
- pc/stackchan-ble-client host test: 109 tests / 0 fail
- 実機: fix 前 `[detail] nil` → fix 後 `[detail] "<YR_actual:2,PU_actual:33>\n"`

## Bug #2: device `flush_one_frame` が CAN_SEND_NOW を chain しない (commit d5dfb5b)

### Symptom
SDK 直叩きスクリプトで `<YL:0>` 連投すると 2 frame 目で `Peripheral not
connected` で abort。1 frame 目の detail 待ちで `ack_timeout=3.0` 超過。

加えて初回観測時 `recv[0]=detail, recv[1]=ACK, recv[2]=detail` の **見かけの
順序逆転** があったが、これは前 disconnect 時の subscription buffer 余波
(キャリーオーバー)。cold-recovery で消失、device-side queue 順序は維持されてた。

### Root cause
`application.rb:771-776` の `flush_one_frame` は 1 frame notify したら return
するだけで、queue に残りがあっても次の `request_can_send_now_event` を chain
しない。残 frame の flush は次の `heartbeat_callback` (1秒周期、line 756 の
`request_can_send_now_event`) を待つしかない。

1 servo command で `@stdout.write(ACK_FRAME)` + `emit_servo_detail` = 2 frame
queue → 1 秒/frame で 2 秒。3 cmd burst で 6 frame queue → 6 秒。host SDK の
`ack_timeout=3.0` を 3 frame 目以降で超過 → CLI abort → 次 write は Mac CoreBT
の `Peripheral not connected` error。

reference: `picoruby/picoruby/mrbgems/picoruby-ble/example/peripheral-central/peripheral/app.rb`
の DemoPeripheral も「1 request → 1 callback → 1 notify」pattern だが、
single-frame workload (sensor reading 1 個 push) なので chain 不要だっただけ。

### Fix
```ruby
def flush_one_frame
  return if @notify_queue.empty?
  frame = @notify_queue.shift
  push_read_value(@tx_handle, frame)
  notify(@tx_handle)
  request_can_send_now_event unless @notify_queue.empty?  # ← 追加
end
```

queue 内全 frame が BLE conn-interval pace で連続 flush される。

### 実機実証 (device-side diagnostic puts 一時投入で確認、確証後撤去)
- heartbeat 周期: 実測 1000-1020 ms (memory note `project_picoruby_ble_heartbeat_tick_one_second` 整合)
- fix 前 (推定): 6 frame で 6 秒、host timeout 確実
- fix 後 (実測): 6 frame queue で flush sequence:
  ```
  t=92981  pre=6  f=2b   ← ACK_F1
  t=93090  pre=5  f=27b  ← detail_F1 (+109ms)
  t=93201  pre=4  f=2b   ← ACK_F2   (+111ms)
  t=93310  pre=3  f=27b  ← detail_F2 (+109ms)
  t=93420  pre=2  f=2b   ← ACK_F3   (+110ms)
  t=93532  pre=1  f=27b  ← detail_F3 (+112ms)
  ```
  **計 551ms / 6 frame、avg 110ms/frame**
- Mac SDK 側受信タイムライン: tx 3 frame 連投 (1ms 以内) → 全 6 frame 受信完了
  1.5 秒以内、順序 ACK,detail,ACK,detail,ACK,detail で逆転なし

### 副次的に判明したこと
前回 observed の「順序逆転 (detail→ACK)」は前 disconnect の Mac CoreBT
subscription buffer キャリーオーバーが原因。cold-recovery で消える。
SDK 側 robust 化 (順序逆転 tolerance) は別 task として残してよいが必須ではない。

## 次フェーズ: HITL calibration (前 handoff から不変)

実機で valid raw 値が読めるようになり、加えて multi-frame protocol が
ack_timeout 内に収まるようになったので、操縦正面アラインと SERVO_*_ZERO /
RANGE_RAW の anchor recal を実行する。

1. **Daily startup**:
   `cd pc/stackchan-ble-client && bundle exec exe/stackchan-ble-control --name-prefix StackChan calibrate --align-only`
   - cold-boot torque OFF → operator が頭を物理正面に → torque ON
2. **5-pose anchor recal**:
   `bundle exec exe/stackchan-ble-control --name-prefix StackChan calibrate [--samples N] [--format ruby|json|env]`
   - 5 pose で sample 取得 → `SERVO_*_ZERO` と `RANGE_RAW` 出力
3. **application.rb 更新**: `mrbgems/picoruby-stackchan-protocol/examples/application.rb`
   の Head class 定数を出力された値で書き換え (現状値:
   `SERVO_YAW_ZERO=460, SERVO_PITCH_ZERO=620, YAW_RANGE_RAW=50, PITCH_RANGE_RAW=30`)
4. **deploy**: `/stackchan-device-iterate` (upload application.rb + reset + boot verify)
5. **HITL visual check**: 0° / 45° / 90° で実物の頭の向きを確認、操縦目的座標と一致するか

Spec: `docs/superpowers/specs/2026-05-21-manual-calibration-cli-design.md`
Plan: `docs/superpowers/plans/2026-05-21-manual-calibration-cli-implementation.md` (Task 23 周辺)

## 環境状態 (次 session 開始時に確認)

### USB / device
- USB 接続済 `/dev/cu.usbmodem1101`
- device 現状: **clean 版 application.rb で cold-boot 完了**、torque OFF、
  Face::Closed (idle indicator)、`<read:pos>` で valid 値返す、BLE adv 中
  (`StackChan-PicoRuby`)
- 直近 raw 値 (selftest 影響後): yaw_raw=459, pitch_raw=630
- 前 handoff の env state (ESP-IDF Python venv `idf5.4_py3.12_env`、
  sdkconfig esp32s3+CoreS3+BTstack) は不変、build 不要

### autostart 注意
application.rb は `loop do peri.start(60_000) end` で永続 BLE peripheral 化
されている → shell prompt は出ない。再 deploy は cold-recovery 必須:
`bundle exec rake r2p2:wipe_storage r2p2:wait[15] r2p2:upload_appmrb SRC=... r2p2:reset`

### Capture の落とし穴 (本 session で詰まった点)
- `bin/capture-with-pty ... rake r2p2:monitor` は内部で `idf_monitor.py` を起動
  → 他の `r2p2:*` task の `ensure_no_concurrent_monitor` guard に引っかかる
  (abort)。subagent が abort を見て勝手に process kill する事故あり
  (security warning 出る) — 並行使用しないこと
- `bundle exec rake r2p2:capture SERIAL_LOG=...` (`cat $port > log`) は
  idf_monitor 不要なので reset と共存可能、ただし USB CDC renum で cat 死ぬ
  ことがある (CoreS3 reset では renum しないが、device 内 panic/reboot 等で
  renum すると終わる)
- 本 session では `r2p2:capture` 経由で smoke evidence 取得成功

### BLE name prefix
`StackChan` (advertising as `StackChan-PicoRuby`)、CLI には `--name-prefix StackChan` で渡す

## Git 状態

- Current branch: `feat/servo-tuning-and-test-fix` @ `d5dfb5b` (clean)
- 前 handoff `c670ada` からの commit (新着 2 個):
  - `614d0e1` fix(ble-client): servo_frame? must match YL/YR/PU 2-char axis keys
  - `d5dfb5b` fix(application): chain CAN_SEND_NOW so multi-frame replies drain in ~110ms/frame
- main との差分: 親 branch の全 commit (本 fix 含む) が未 merge — main 統合は別途判断

## このセッションで学んだ知見 (CLAUDE.md 候補)

- **picoruby-ble の peripheral で multi-frame queue を持つアプリは
  `request_can_send_now_event` を flush 後に chain する必要がある**。reference
  の DemoPeripheral は single-frame workload なので chain なしで動くが、
  multi-frame アプリで heartbeat (~1s) 縛りになると 1 秒/frame の累積遅延
- **`cat $port` capture は CoreS3 reset では生き残る** (USB CDC renum しない)
  が device 側 panic/reboot で renum すると死ぬ。`bin/capture-with-pty` は
  idf_monitor 経由なので reset と並行使用すると ensure_no_concurrent_monitor
  guard に引っかかる → トレードオフ
- **subagent に PID kill 権限を与えない**: rake task の abort message を見て
  subagent が prompt 指示なく `kill <pid>` を実行する事故が起きた
  (security warning 出る)。subagent dispatch 時は instructions に
  「DO NOT kill any process or PID」を明示すること
- **Mac CoreBluetooth は disconnect 後の notify を新 connect 時に flush する**
  ことがある (本 session で `recv[0]=detail, recv[1]=ACK, recv[2]=detail` の
  順序逆転として観測、cold-recovery で消失)。SDK 側で順序逆転 robustness は
  別 task の余地あり (現状の chain-flush fix で実用上問題なし)

## 終了

本 debug session の scope はここで終了。次 session は HITL calibration
(前 handoff の Task 23) を起点に進める。device は valid 値 read + multi-frame
protocol 健全の両方を満たした状態で待機中。
