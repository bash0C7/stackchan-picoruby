# Handoff 2026-05-21 (device-resume): cold-boot redesign implementation continuation

## TL;DR for next session

`docs/superpowers/plans/2026-05-21-cold-boot-torque-off-and-normalized-protocol-plan.md` の Phase 1-7 のうち host-only 範囲 (Tasks 1, 4-14, 16-23) 完了。**20/25 task ✅**。残り 4 task が CoreS3 device 必須 (2, 3, 15, 24)、最後の Task 25 (PR open) がそれらに依存。

## Current branch state

- Branch: `feat/servo-tuning-and-test-fix`
- HEAD: `a270236` (`fix(notifier): align servo CLI with new direction-key (YL/YR/PU) protocol`)
- Working tree: clean
- Host test state: **全 4 suite 100% pass** (root 61 / mrbgem 31 / ble-client 73 / notifier 72)

## Resume trigger

User 任意。「device 繋いだ」「Task 2 続き」「impl 再開」「stackchan やろ」「Phase 8 やる」等。

## Execution mode (継続)

**`superpowers:subagent-driven-development`** — fresh subagent per task + 2-stage review (spec compliance + code quality)。inline 直 edit は 1-line edit のみ。

## Tasks completed (20/25)

| Phase | Tasks | 主要 commit |
|---|---|---|
| 1 (scservo) | 1, 4 | `582015f`, `2099c64`, `4282c25` |
| 2 (Face::Closed) | 5, 6, 7 | `c941887`, `3d0b767`, `9a0b05f` |
| 3 (Dispatcher) | 8, 9, 10, 11, 12, 13 | `8ba22e6`, `d0c912e`, `46eeada`, `ce9a930`, `4d0752d`, `6c25365`, `5601e8d` |
| 4 (cold-boot) | 14 | `bebcd93` |
| 5 (PC client) | 16, 17, 18 | `c8fb237`, `8ce931d`, `59ae688` |
| 6 (Rakefile) | 19, 20, 21 | `6e3ad44` (コード only、device smoke 走査は次セッション) |
| 7 (docs + sweep) | 22, 23 | `c257176`, `a270236` |

## Tasks BLOCKED on device (4)

| Task | Current state | Next action |
|---|---|---|
| 2 | Step 1 (application.rb edit) `1e56581` 済 | `/stackchan-device-build-flash` (~10min、scservo mrbgem 変更込み) → `/stackchan-device-iterate` (~50s) → boot.log の `[diag read_pos_raw id=N]` を 4 hypothesis layout (echo only / no echo+response / wrong register / silent) に分類 |
| 3 | Pending Task 2 output | Branch A (drain_echo no-op) / B (wrong register, SCSCL.h 照合) / C (force_drain_rx) のいずれかを Task 2 の raw byte dump で決定。Plan §Task 3 lines 177-264 参照 |
| 15 | Pending Task 14 cold-boot deploy | `/stackchan-device-iterate` で boot.log 取って 5 assertion (LCD cold-boot torque-OFF idle / servo init OK torque OFF / no enable_torque line / no self-test line / Face::Closed visible + servos hand-movable) を確認。Plan §Task 15 lines 1191-1209 |
| 24 | Pending device + operator standby | `bundle exec rake r2p2:ble_calibration_check` (HITL 5-position Y/N prompt)。Task 24 dispatch 前に必ず user に「実機の前にスタンバイ可能か?」確認 |

## Task 25 (PR open) — DoD 現状

完了済 (host side or spec-evident):
- DoD #6 `<YL:150>` ERROR (host test, Task 10)
- DoD #7 `<YL:50,YR:30>` YL wins (host test, Task 10)
- DoD #9 host side unknown fallback (Task 11 test)
- DoD #11 `rake test` all pass + `face_closed.sha256` locked (Task 6)
- DoD #12 grep sweep zero (Task 23、live code clean、historical plan 文書のみ残存)
- DoD #13 CLI subcommand parsing verified (Task 18 smoke)

Device session 必要:
- DoD #1, #2, #3 (cold-boot device behavior + torque on/off frames)
- DoD #4 `<selftest:run>` 実機実行
- DoD #5 `<YL:N,PU:M,T:tt>` ACK + detail (ble_servo_smoke 走査)
- DoD #8 Combo `<F:2,YL:50,L:1,...>` 実機送信
- DoD #10 HITL 5-position PASS (= Task 24)

## Critical findings during execution (再現防止用)

### 1. Task 1: FakeUART auto-echo と plan-literal `<empty>` test の矛盾

Plan §Task 1 Step 1 の 2 つめの test (`test_read_pos_raw_debug_returns_empty_marker_when_no_response`) は bare `FakeUART.new` 使用で `assert_equal "<empty>"` を期待しているが、`FakeUART#write` が TX bytes を `@pending_rx` に自動 echo するため `"<empty>"` path は到達不可能。

**Fix (commit `2099c64`)**: `FakeUART#initialize` に `echo:` kwarg 追加 (default `true` 後方互換)。`FakeUART.new(echo: false)` で plan-literal test 復活させた。

**Why this matters for device deploy**: 実 ESP32-S3 UART1 の wiring が echo を loop back するかどうかは未確定。Task 2 の `read_pos_raw_debug` 出力が:
- echo bytes (`FF FF <id> 04 38 02 <cksum>`) で始まる → echo present → Branch A (drain_echo no-op はあかん、別 hypothesis 探す) もしくは Branch C
- response (`FF FF <id> 04 00 <pos_l> <pos_h> <cksum>`) で始まる → no echo → Branch A (drain_echo を no-op 化、check_head が即座 response 読む)
- `<empty>` → UART config / wiring 根本的に違う、別 deep diag task

### 2. Task 10 collateral 9 failure

Task 10 で Head class rewrite (kwargs apply + symbol-key read_actual) と Dispatcher#handle の servo_present 切替 (Y/P/V/T → YL/YR/PU) したら、root-level の `test/head_test.rb` (9 errors) + `test/dispatcher_servo_test.rb` (9 failures) が壊れた。Plan の sequencing 想定の甘さ。

**Fix-up (commit `ce9a930`)**: head_test.rb は新 kwargs 対応に更新 (5 tests rewrite + 6 obsolete tests omit)、dispatcher_servo_test.rb は 9 tests omit pending Task 12。

### 3. Task 11 latent bug: emit_servo_detail の @head=nil crash

Task 10 で `handle_head` が `return true if @head.nil?` (= servo unavailable でも ACK 返す) という仕様にしたら、その後 `emit_servo_detail(frame) if success` が呼ばれて `@head.read_actual` で NoMethodError。

**Fix (commit `6c25365` Task 12 内)**: emit_servo_detail の冒頭に nil-guard 追加:
```ruby
if @head.nil?
  @stdout.write("<YL_actual:unknown,PU_actual:unknown>\n")
  return
end
```

これ自体が protocol spec 通り (unknown = operator-intervention signal)。

### 4. Task 23 grep sweep が plan 外で live API breakage 発見

`pc/stackchan-notifier/lib/stackchan_notifier/handlers/servo_handler.rb` が `s.head(yaw:, pitch:, time_ms:, velocity:)` 呼んでた → Task 17 で SendBuilder#head signature 変わったから次回 production invoke で ArgumentError crash。

**Fix (commit `a270236`)**: 11 file 更新で notifier 全体を direction-key 化:
- `servo_cli.rb`: `--yaw/--pitch` → `--yaw-left/--yaw-right/--pitch-up` (Option B = normalized magnitudes 0-100)
- `servo_handler.rb`: SendBuilder#head 新 kwargs
- `notify_motion_table.rb`: raw encoder → normalized magnitude 変換
- `notify_handler.rb`: motion table 新 key
- `helper.rb` (FakeSendBuilder), 5 個の test file, README

設計判断 Option B: pitch-down は protocol-unreachable (cold-boot redesign の safety constraint 通り)。raw 値での expressiveness は失うが、wire protocol 整合性優先。

**Lesson**: plan の `File Structure / Modified files` list は plan 作成時の認識のみ。grep sweep (Task 23) が真の影響範囲を出すので、Phase 7 の grep は必ず走らせる。

## Implementation deviations from plan

| Plan指定 | 実装 | 理由 |
|---|---|---|
| Task 1 Test 2 `assert_equal "<empty>"` (bare `FakeUART.new`) | `FakeUART.new(echo: false)` + 追加 echo-capture test | FakeUART auto-echo で literal が通らない、kwarg で plan-literal 復活 |
| Task 8 plan §Step 4 で `handle` 全 rewrite snippet (YL/YR/PU 切替込み) | torque branch のみ prepend、他は touch せず | Task 10 まで YL/YR/PU 検出も legacy Y/P 削除も入らないから既存 test 守る |
| Task 9 plan Test 1 が detail frame 期待 | detail なしで ACK のみ assert に縮小、Task 11 で detail wire-up | emit_servo_detail 新フォーマットは Task 11 で initialize されるため |
| Task 10 で `test/head_test.rb` + `test/dispatcher_servo_test.rb` 触る | 触った (collateral fix) | plan が scope に入れてなかったが Head class 直接 test なので Task 10 logical scope |
| Task 12 で `emit_servo_detail` nil-guard 追加 | 同 commit で fix | 別 task に分けるほどでもない 1-block 改修、Task 12 commit msg に明記 |
| Task 14 self-test block 削除 | 削除 + `[application] LCD + LED cold-boot done` → `LCD cold-boot done (torque-OFF idle)` | plan 通り、log marker も新仕様反映 |
| Task 16/17 で `pc/stackchan-notifier` 更新 | Task 23 grep sweep で fix (commit `a270236`) | plan の Modified files list に notifier 入ってなかったため後追い |

## Hidden constraints / pitfalls (継承)

### Application.rb 全般 (CLAUDE.md / handoff prior 参照)
- **PY32 init region の 5 puts 削除禁止** (`application.rb:521-547` 周辺) — `project_py32_init_puts_required`
- **cold-boot 後 `sleep_ms 3000` 必須** — `project_ble_phase3_btstack_starve_finding`
- **on-device require は hyphen 形式** (`require 'stackchan-protocol'`)
- **mrblib 内 sibling require 禁止**、cross-gem は OK

### Test infrastructure
- Host test は prism AST extraction (`lib/ruby_class_extract.rb`) で application.rb の class を抽出
- `BLE < ...` exclude filter — class body top-level に `< BLE` 書かない
- `test/test_helper.rb` で Machine / UART / ILI9342::Color stub
- `test/fake_uart.rb` の `echo:` kwarg (Task 1 追加) + `read_queue_after_writes` (Task 4 追加)

### Subagent dispatch (再確認)
- verify 系 subagent に **production code 改変禁止** 明示 (`feedback_subagent_no_code_workaround_during_verify`)
- per-task review に加えて Phase 終了時 final code-reviewer step skip しない (`feedback_final_review_catches_what_per_task_misses`)
- main は orchestrator として subagent report 吟味 + 分岐判定のみ (`feedback_main_as_orchestrator`)

### Device-side iteration
- 全 device op は `stackchan-device-*` skill 経由、`rake r2p2:*` を main から直接叩かない
- 失敗 escalation: `cold-recovery` → `full-rebuild` → human (2 try で escalate)
- serial capture は `bin/capture-with-pty` (CDC renum 対策)
- boot 失敗診断は **full log を取ってから** 仮説立てる
- **scservo mrbgem 変更時は `r2p2:build_flash` 必須** (今回 Task 1+4 で scservo 変更したから初回 device deploy で必要)
- build_config は touch なし、`r2p2:setup` 不要

### Task 24 HITL 前提
- operator 必須。Task 24 dispatch 前に user に「実機の前にスタンバイ可能か?」確認してから rake task 起動。自動 dispatch しない

## Mac BLE 経由検証時 (Task 24 + Task 25 DoD #5, #8)

- Mac CoreBluetooth は GATT 0 services 永続キャッシュ (`feedback_mac_corebluetooth_gatt_cache_trap`)。詰まったら iPhone nRF Connect で並行検証
- device name は scan response から取る、discoverServices(nil) は 0x1800/0x1801 除外 (`feedback_apple_corebluetooth_gap_gatt_filter`)
- claude 自身が rb-corebluetooth-mac で scan/connect/write 可能 (`feedback_claude_can_do_mac_ble_scan`)
- name suffix 切り捨て注意、`--name-prefix StackChan-PicoRuby` で OK (`feedback_mac_scan_truncates_epoch`)

## Quick start (次セッション、1 行)

```
device 繋いで build_flash + Task 2 capture スタートしてくれ
```

Main の動き:
1. `superpowers:subagent-driven-development` skill invoke
2. Task 2 in_progress に
3. `/stackchan-device-build-flash` (haiku subagent foreground, 600s timeout) — scservo mrbgem + cold-boot 変更を device に焼く
4. `/stackchan-device-iterate` (haiku subagent foreground, 50s) — application 上書き + reset + boot.log capture
5. boot.log を `grep "[diag read_pos_raw id=" /tmp/stackchan-picoruby-debug/*.log` して 4 layout 分類
6. Task 3 dispatch (Branch A/B/C 決定済みの状態で)
7. Task 15 として再度 `/stackchan-device-iterate` (Task 14 cold-boot rewrite を device で確認、`LCD cold-boot done (torque-OFF idle)` log assert)
8. Task 24 前に user 確認 → HITL run
9. Task 25 = PR open (DoD 表埋めて `gh pr create`)

## 関連 memory (継承、`~/.claude/projects/-Users-bash-dev-src-github-com-bash0C7-stackchan-picoruby/memory/`)

主要参照:
- `feedback_servo_absolute_pos_is_core` — 本質は BLE 経由絶対位置制御
- `project_actual_unknown_signals_manual_cal` — `unknown` is operator-intervention signal (not fallback)
- `project_ble_phase3_btstack_starve_finding` — cold-boot 後 sleep_ms 3000 必須
- `project_design_d_app_side_and_skills` — Face/Dispatcher は application.rb
- `feedback_picoruby_uart_on_device_api` — `:ESP32_UART1` / String only write / positional read
- `feedback_new_gem_needs_r2p2_setup` — build_config 変更時のみ (今回該当せず)
- `project_py32_init_puts_required` — application.rb PY32 init 区の 5 puts 削除禁止
- `feedback_local_commit_autonomy_bash0c7_only` — bash0C7/* repo はローカル commit user 確認不要 (本セッション 20+ commit 自律)
- `feedback_mac_corebluetooth_gatt_cache_trap` / `feedback_apple_corebluetooth_gap_gatt_filter` / `feedback_mac_scan_truncates_epoch` — Mac BLE 経由検証時
- `feedback_subagent_no_code_workaround_during_verify` / `feedback_final_review_catches_what_per_task_misses` / `feedback_main_as_orchestrator`

## Out of scope (次セッションでも対象外)

- PRESENT_LOAD / PRESENT_MOVING (level 2 read) — read_pos 解決後の future evolution
- detail frame 完全自動化 (numerical assertion) — read_pos 解決時のみ
- calibration の persistent storage — 別 spec
- BLE pairing / authentication — open NUS 維持

## Git state (このハンドオフ commit 前)

- Branch: `feat/servo-tuning-and-test-fix`
- HEAD: `a270236`
- 直近 commit graph (新→旧):
  ```
  a270236 fix(notifier): align servo CLI with new direction-key (YL/YR/PU) protocol
  c257176 docs: mark Phase B servo design superseded + add new protocol section to CLAUDE.md
  6e3ad44 chore(rake): ble_servo_smoke YL/YR/PU syntax + new ble_torque_smoke + ble_calibration_check
  59ae688 feat(ble-control): new CLI — --yaw-left/--yaw-right/--pitch-up, torque, selftest subcommands, EXIT_CALIBRATION_NEEDED on unknown
  8ce931d feat(send_builder): head(yaw_left:, yaw_right:, pitch_up:) + torque + selftest
  c8fb237 feat(frame_codec): direction-key encode_head (yaw_left/yaw_right/pitch_up) + encode_torque + encode_selftest
  bebcd93 feat(application): cold-boot torque-OFF + Face::Closed idle (operator aligns then sends <torque:on>)
  5601e8d feat(dispatcher): reject legacy Y/P raw frames with ERROR ACK (raw protocol retired)
  6c25365 test(dispatcher): rewrite servo tests to direction-key (YL/YR/PU) syntax + nil-head guard
  4d0752d feat(dispatcher): emit_servo_detail with YL/YR/PU_actual + unknown fallback
  ce9a930 test: fix Task 10 collateral breakage (head_test update + dispatcher_servo_test omit until Task 12)
  46eeada feat(dispatcher): handle <YL/YR:N,PU:M> position frames with range check + conflict resolution
  d0c912e feat(dispatcher): handle <selftest:run> — yaw ±10 raw sweep + ACK (detail TBD Task 11)
  8ba22e6 feat(dispatcher): handle <torque:on|off> — enable/disable + Face transition
  9a0b05f refactor(face): blink uses redraw_eyes_closed (preserves mouth, no flicker)
  3d0b767 test(face): lock Face::Closed golden SHA (new wire-protocol face for torque-off idle)
  c941887 refactor(face): Closed#draw = full-fill + closed eyes only; Base#redraw_eyes_closed for blink
  4282c25 feat(scservo): retry read_pos up to 3 times before returning nil
  1e56581 diag(scservo): emit raw read_pos RX bytes during cold-boot diagnostic block
  2099c64 test(scservo): exercise read_pos_raw_debug <empty> path via FakeUART echo:false
  582015f feat(scservo): add read_pos_raw_debug for echo/response diagnostic
  84d0b96 docs(handoff): next-session implementation start for cold-boot redesign
  bf842b6 docs(plan): add cold-boot torque-off and normalized protocol implementation plan
  ba521e5 docs(spec): cold-boot torque-off and normalized BLE frame protocol design
  ```
- Origin: `github.com/bash0C7/stackchan-picoruby` (ローカル commit autonomy 適用、push は user 指示で)

## Skills 推奨 (次セッション)

- **`superpowers:subagent-driven-development`** — 継続実装 skill
- `stackchan-device-build-flash` — 初回 device deploy (~10min)
- `stackchan-device-iterate` — Task 2 / Task 15 / 各 device 検証
- `stackchan-device-boot-verify` — Task 15
- `stackchan-device-cold-recovery` / `full-rebuild` — 失敗 escalation
- `superpowers:systematic-debugging` — Task 3 hypothesis 探索で
- `reference-first-debug` — Task 3 Branch B (`../StackChan/firmware/main/hal/drivers/FTServo_Arduino/SCSCL.h` 照合) で
- `superpowers:verification-before-completion` — Task 24 + Task 25 直前
- `superpowers:requesting-code-review` — Task 25 PR 開く前
