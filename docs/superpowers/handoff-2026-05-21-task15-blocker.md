# Handoff 2026-05-21 (task15-blocker): cold-boot torque-OFF実機NG、BLE manual cal fallbackへ

## TL;DR for next session

Phase 1-7 host 全完了 + device deploy verified (Task 2, 3 解消)。**Task 15 で blocker**: cold-boot で explicit `enable_torque(false)` 呼んでも実機 servo の torque が OFF にならん (HITL 確認、commit `3c93ff7`)。User 方針: **BLE `<torque:off>` 経由 operator manual cal に fallback**。USB 抜いて次セッション仕切り直し。

## Resume trigger

USB 繋ぎ直したら「Task 15 続き」「BLE manual cal いこ」「torque off fallback やる」「stackchan やろ」など。

## Branch state

- Branch: `feat/servo-tuning-and-test-fix`
- HEAD: `3c93ff7` (fix(application): explicit enable_torque(false) at cold-boot)
- Working tree: clean
- Host test: **全 4 suite 100% pass** (root 61 / mrbgem 31 / ble-client 73 / notifier 72)

## Task progress (25/25 plan tasks)

| Phase | Status | 主要 commit |
|---|---|---|
| 1 scservo (Task 1, 4) | ✅ | `582015f`, `2099c64`, `4282c25` |
| 2 Face::Closed (Task 5-7) | ✅ | `c941887`, `3d0b767`, `9a0b05f` |
| 3 Dispatcher (Task 8-13) | ✅ | `8ba22e6`-`5601e8d` |
| 4 cold-boot (Task 14, 15) | **⚠️ blocker** | `bebcd93`, `3c93ff7` |
| 5 PC client (Task 16-18) | ✅ | `c8fb237`, `8ce931d`, `59ae688` |
| 6 Rakefile (Task 19-21) | ✅ | `6e3ad44` |
| 7 docs + sweep (Task 22, 23) | ✅ | `c257176`, `a270236` |
| Task 2 (device diag) | ✅ resolved | `1e56581` deploy + capture (boot-task3.log) |
| Task 3 (read_pos fix Branch A) | ✅ | `1171639`, `3482f39` |
| Task 24 (HITL 5-position) | pending (Task 15 解消後) | — |
| Task 25 (PR open) | pending (Task 24 解消後) | — |

## Task 15 finding 詳細

### 何があったか

1. commit `bebcd93` (Task 14) で「servo init 時に enable_torque を呼ばない、デフォルト torque-OFF と仮定」とした
2. 実機検証 (HITL #1): Face::Closed 出るが **servo に抵抗あり** = torque ON のまま
3. Hypothesis: SCS の EEPROM default が torque ON。明示的に `enable_torque(false)` 必要
4. commit `3c93ff7` で `yaw_servo.enable_torque(false); pitch_servo.enable_torque(false)` 追加 (Head.new 前)
5. 実機検証 (HITL #2): **servo にまだ抵抗あり** = enable_torque(false) 効いてない or hardware が想定外挙動

### 観測した事実

boot-task15-verify.log key lines:

```
105:[application] LCD cold-boot done (torque-OFF idle)
107:[boot] servo init OK (torque OFF, awaiting <torque:on>)
108:[diag id=1] PING tx=FF FF 01 02 01 FB raw_rx=FF FF 01 02 00 FC
109:[diag id=2] PING tx=FF FF 02 02 01 FA raw_rx=FF FF 02 02 00 FB   ← err=0x00 (前回は 0x20)
```

ID=2 の PING err byte が `0x20` → `0x00` に変化してるから `enable_torque(false)` の write 自体は通ってる (overload error がクリアされた)。けど物理的には torque が抜けてない (operator HITL feedback)。

### 仮説候補 (次セッションで検証)

A. **SCS protocol の torque register が SCSCL/SMS_STS で違う**。我々の REG_TORQUE=0x28 (SCSCL_TORQUE_ENABLE=40) は SCSCL 規約。実機が SMS_STS variant なら register 違う
B. **multi-turn mode で torque-disable が無効**。連続回転 360° servo は torque を切らない (= mechanical brake が残る) hardware 仕様の可能性
C. **operator が感じてる「抵抗」が active torque ではなく gear/磁気 cogging**。SCS 系 servo は power off でも内部ギア cogging で手で動かしにくい
D. **gen_write の ack 失敗を silent に飲んでる**。`gen_write` の return value (ack 結果) を call site で check してない、書き込み失敗してても無音で進む可能性

### User 方針 (確定)

**BLE 経由 operator manual cal に fallback**:
- cold-boot torque-OFF 試行は維持 (best-effort、ベストエフォートで OFF にいくが保証しない)
- operator が Mac BLE 経由で `<torque:off>` 送信
- claude 自身が rb-corebluetooth-mac で送信可能 (memory: `feedback_claude_can_do_mac_ble_scan`)
- physical alignment 後 operator が `<torque:on>` 送って calibration

### 次セッション次手順 (proposed)

1. USB 繋ぎ直し、device 状態確認 (`/stackchan-device-capture-boot`)
2. **直接 BLE `<torque:off>` 送って物理確認**:
   - `bundle exec exe/stackchan-ble-control --torque-off torque` (CLI exists per commit `59ae688`)
   - これで実際に torque 抜けるか確認 → A 仮説 (register 違い) or B 仮説 (multi-turn no-effect) の切り分け
3. If still has resistance after BLE `<torque:off>`:
   - cogging 説 (C) 採用、HITL 用語を「動くか」ではなく「軽く動かせるか」に緩和
   - もしくは BMI270 等 IMU で「torque-OFF の状態 = 自由落下方向に頭が向く」を確認
4. Task 24 (HITL 5-position) は torque OFF できた状態で実行 (BLE 送ってから)
5. Task 25 (PR open) で DoD #1-3 を「cold-boot best-effort torque-OFF, BLE-driven manual cal が primary path」に書き直し
6. Spec doc (`docs/superpowers/specs/2026-05-21-cold-boot-torque-off-and-normalized-protocol-design.md`) も同様に更新

## 実機物理状態 (USB 抜く直前、参考)

User 申告:
- **Yaw (ID=1)** servo: 真後ろ向き
- **Pitch (ID=2)** servo: 真上向き
- **LCD**: Face::Closed visible (黒背景 + 横線2本の閉じ眼) ✓
- **Servo torque**: ON のまま (手で動かすと抵抗あり、HITL #2 で確認)

read_pos raw values (boot-task15-verify.log):
- 出てない (commit `3c93ff7` で Task 3 verify 用 temp diag は revert 済)
- 旧 boot-task3.log の値: yaw=-27139 (真後ろ向き at), pitch=-12291 (真上向き at)
- これは Task 24 calibration anchor 候補 (memory: `project_read_pos_branch_a_finding`)

## Phase B 仮想再校正の論点 (Task 24 で扱う)

`SERVO_YAW_ZERO=460` / `SERVO_PITCH_ZERO=620` (12-bit 範囲) は Phase B 時の anchor。今回の cold-boot torque-OFF 動作の中で操作者が「正面」物理整列したら、その raw position を新 SERVO_*_ZERO に再 anchor する作業必要。

read_pos が multi-turn 負値返す現象は Task 3 Branch A 後の挙動なので、`delta = raw - ZERO` 計算は raw が想定外範囲だと壊れる。`emit_servo_detail` (application.rb:417-) の `actual:unknown` fallback (nil check) を operator-intervention signal として活用可能。

## Critical findings 追加 (継承)

### 1. PicoModem upload 不安定 (本セッション)

- `FILE_ACK got nil` 連発 → wipe_storage で /home/app.mrb クリアしたら通る
- `wipe_storage` (1.9MB 全 partition flash する `r2p2:flash` と違って) は 0x210000-0x310000 の 1MB だけ erase + hard reset。`/home/app.mrb` autostart を消す軽量 escape hatch
- subagent dispatch だと 180s timeout で DONE_ACK 待ち到達前に終わる → 直接 Bash で 240s+ 必要なケースあり
- 一度 upload 通ったら次もそのまま autostart で BLE loop が STDIN 占有 → wipe_storage 再実行が必要
- 解決パターン: `wipe_storage → r2p2:wait[8] → upload_appmrb` の chain (本セッション最終で確認)

### 2. Cold-boot 後 sleep_ms 3000 維持 (継承、変更無し)

`project_ble_phase3_btstack_starve_finding` 参照。BTstack task starve 回避の必須 yield。

### 3. read_pos returns multi-turn negative values

Task 3 Branch A 後の挙動。decode_signed は End=0 LE consistent。値が想定外範囲なのは continuous-rotation servo の multi-turn position 仕様。Task 24 の calibration anchor 確定で SERVO_*_ZERO 再校正が必要になる可能性高い。

## Out of scope (次セッションでも対象外)

- write_pos の encode_signed byte order 検証 (Phase B HITL で動作確認済なので変更しない)
- read_pos の sign convention 変更 (decode_signed は対称的、現状維持)
- BLE pairing / authentication (open NUS 維持)
- detail frame numerical assertion 自動化 (read_pos 範囲確定後)

## Skills 推奨 (次セッション)

- **`superpowers:subagent-driven-development`** — 継続実装 skill
- `stackchan-device-build-flash` — 必要なら (今回 mrbgem 変更無いと build_flash 不要、`r2p2:upload_appmrb` だけで OK)
- `stackchan-device-cold-recovery` — upload 詰まった時 (wipe + upload + reset)
- `stackchan-device-iterate` — application.rb 変更 → device verify
- `stackchan-device-capture-boot` — USB 抜き挿し直後の state 確認
- `reference-first-debug` — torque-OFF が効かない真因調査 (SCSCL.h vs SMS_STS variant の照合)
- `superpowers:systematic-debugging` — 仮説 A-D の bisect

## 関連 memory (継承、`~/.claude/projects/-Users-bash-dev-src-github-com-bash0C7-stackchan-picoruby/memory/`)

主要参照:
- `feedback_servo_absolute_pos_is_core` — stackchan の本質は BLE 経由絶対位置制御
- `project_actual_unknown_signals_manual_cal` — `<Y_actual:unknown>` = operator manual cal シグナル
- **`project_read_pos_branch_a_finding`** (本セッション追加) — multi-turn position の解釈、Task 24 anchor 再校正の前提
- `project_ble_phase3_btstack_starve_finding` — cold-boot 後 sleep_ms 3000 必須
- `feedback_picoruby_uart_on_device_api` — UART API gotchas
- `project_py32_init_puts_required` — application.rb PY32 init 区の 5 puts 削除禁止
- `feedback_local_commit_autonomy_bash0c7_only` — bash0C7 origin local commit autonomy
- `feedback_mac_corebluetooth_gatt_cache_trap` / `feedback_apple_corebluetooth_gap_gatt_filter` / `feedback_mac_scan_truncates_epoch` — Mac BLE 経由検証時
- `feedback_subagent_no_code_workaround_during_verify` / `feedback_final_review_catches_what_per_task_misses` / `feedback_main_as_orchestrator`

## Git state このハンドオフ commit 前

- Branch: `feat/servo-tuning-and-test-fix`
- HEAD: `3c93ff7`
- 直近 commit (新→旧):
  ```
  3c93ff7 fix(application): explicit enable_torque(false) at cold-boot
  3482f39 chore(scservo): clean up stale comments + remove vacuous drain_echo test
  1171639 fix(scservo): drain_echo no-op — ESP32-S3 UART1 has no echo loopback
  82fff33 docs(handoff): device-resume handoff after host phases 1-7 complete
  a270236 fix(notifier): align servo CLI with new direction-key (YL/YR/PU) protocol
  ```
