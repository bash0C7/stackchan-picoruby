# Handoff 2026-05-21 (impl-start): cold-boot redesign implementation kickoff

## TL;DR for next session

Brainstorming → spec → plan の流れ完了。次セッションは **subagent-driven-development skill** で Phase 1 Task 1 から実装スタート。

| 成果物 | Path | Commit |
|---|---|---|
| Spec doc | `docs/superpowers/specs/2026-05-21-cold-boot-torque-off-and-normalized-protocol-design.md` | `ba521e5` |
| Implementation plan | `docs/superpowers/plans/2026-05-21-cold-boot-torque-off-and-normalized-protocol-plan.md` | `bf842b6` |
| Handoff (this file) | `docs/superpowers/handoff-2026-05-21-implementation-start.md` | (uncommitted at writing time) |

## Resume trigger

User 任意。「impl 続き」「次セッション開始」「Phase 1 やる」「subagent-driven 起動」「stackchan やろ」等。

## Execution mode (user 確定済)

**`superpowers:subagent-driven-development`** — fresh subagent per task + main session が task ごとに 2-stage review (per-task + final code-reviewer)。Inline execution は不採用。

## 開始 task

**Phase 1 Task 1: scservo `read_pos_raw_debug` diagnostic method 追加** (plan §Task 1)

- Files: `mrbgems/picoruby-scservo/mrblib/scservo.rb` + `test/scservo_test.rb`
- 純粋 host TDD、device touch なし、~5-10 min subagent dispatch で完了する size
- 完了後すぐ Task 2 (実機 boot.log 取得) に進めば、Task 3 の hypothesis branch (echo absent / wrong register / clear_rx_buffer) を即決定できる

## Plan の Phase 構成 (要約のみ、詳細は plan を読む)

| Phase | Task # | 内容 | 主要 risk |
|---|---|---|---|
| 1 | 1-4 | scservo read_pos deep debug + retry policy | **Task 3 は分岐 task** — Task 2 の実機 raw byte dump 出力次第で 3 branch から 1 つ選ぶ。全 branch fail なら fallback 受容 (spec Section 5 の `unknown` path) |
| 2 | 5-7 | Face::Closed full-fill 化 + Base#redraw_eyes_closed 切り出し + golden lock | golden SHA 生成手順は既存 face_golden_test.rb の registration mode を確認してから |
| 3 | 8-13 | Dispatcher 新 handler (torque/selftest/YL/YR/PU) + 旧 Y/P key 廃止 | host test only、各 task は TDD red→green→commit の bite-sized |
| 4 | 14-15 | cold-boot rewrite + 実機 boot-verify | Task 14 で `enable_torque` + self-test ブロック削除、PY32 init region の 5 puts marker は **削除禁止** (memory: `project_py32_init_puts_required`) |
| 5 | 16-18 | PC client (frame_codec / send_builder / exe) 書き換え | Mac CoreBluetooth 経由なので Mac scan の epoch suffix 制約 (memory) を意識 |
| 6 | 19-21 | Rakefile に新 ble_servo_smoke / ble_torque_smoke / ble_calibration_check task | rake task は全部 subagent foreground (haiku) で 1 chain ずつ呼ぶこと (CLAUDE.md project rule) |
| 7 | 22-23 | docs sweep (Phase A/B spec + CLAUDE.md) + 旧 raw frame grep clean | |
| 8 | 24-25 | HITL 5-position visual check + DoD 13 項 check | **operator (人間) 必須** — 自動完結不可、人間にスケジュール確認してから dispatch |

## 確定した design 主要 decision (spec doc に集約済、再確認用)

1. **Frame syntax**: `<YL:N>`/`<YR:N>` (yaw、排他で **YL 優先**) + `<PU:N>` (pitch up only、down 不可) + `<T:ms>`/`<V:val>` (Phase B 維持) + `<torque:on|off>` + `<selftest:run>` (rare event は full word key)
2. **LED と servo の L/R 衝突回避**: servo を `YL/YR/PU` に rename。LED 側 (`L:1,R:..,G:..,B:..`) は不変、同一 frame combo 可能
3. **cold-boot**: torque OFF で起動 + Face::Closed indicator + 人間が手で正面アライン → `<torque:on>` でロック
4. **detail frame**: 成功 = `<YL_actual:N,PU_actual:N>` (input symmetric)、失敗 = `<YL_actual:unknown,PU_actual:unknown>` = **operator 介入 signal** (単なる fallback じゃない)
5. **read_pos**: deep debug を scope 内、解決失敗時は unknown fallback で完成扱い

## 重要な hidden constraint / pitfall (subagent に必ず伝えるべき)

### Application.rb 全般
- **PY32 init region の 5 puts は削除禁止** marker (`application.rb:425-432` 周辺)。`project_py32_init_puts_required` memory 参照
- **cold-boot 後 `sleep_ms 3000` で yield 必須** (`project_ble_phase3_btstack_starve_finding`)。BLE adv silent fail 防止
- **on-device require は hyphen 形式** (`require 'stackchan-protocol'`、underscore は LoadError)
- **mrblib 内 sibling require 禁止** (device で fail)、cross-gem require は OK

### Test infrastructure
- Host test は prism AST extraction (`lib/ruby_class_extract.rb`) で application.rb の class を抽出
- `BLE < ...` exclude filter があり、class body top-level に `< BLE` パターンを書かんこと
- `test/test_helper.rb` で `Machine` module / `UART` module / `ILI9342::Color` 等 host stub 済み
- `test/fake_uart.rb` の `read_queue_after_writes` 機構は Plan Task 4 で追加が必要

### Subagent dispatch
- subagent には **production code 改変禁止 (verify 系の場合)** を明示すること (`feedback_subagent_no_code_workaround_during_verify`)
- 各 task の per-task review に加えて、**Phase 終了時に final code-reviewer step を絶対 skip しない** (`feedback_final_review_catches_what_per_task_misses`)
- main は orchestrator として report 吟味、分岐判定だけ (`feedback_main_as_orchestrator`)

### Device-side iteration
- 全 device op は `stackchan-device-*` skill 経由、`rake r2p2:*` を main から直接叩かない (CLAUDE.md project rule)
- 失敗時 escalation: `cold-recovery` → `full-rebuild` → human (2 try で escalate)
- serial capture は必ず `bin/capture-with-pty` (CDC renum 対策)
- boot 失敗診断は **full log を取ってから** 仮説立て、最初の異常から順に読む
- `mrbgem`/`build_config` 変更時は `r2p2:setup` フル必須 (`feedback_new_gem_needs_r2p2_setup`)

### read_pos deep debug の expected outcome (Task 2 観察ポイント)
boot.log の `[diag read_pos_raw id=N]` 行から:
- **echo only** (`FF FF <id> 04 38 02 <cksum> ...` で停止): Branch A (echo absent じゃなくて echo present、drain_echo 正しく動いてる、check_head が timeout 原因)
- **no echo, valid response** (`FF FF <id> 04 00 <pos_l> <pos_h> <cksum>` から始まる): Branch A — drain_echo no-op 化
- **wrong response layout** (LEN/data byte 違い): Branch B — register address 再確認
- **silent failure** (`<empty>`): UART config か wiring が根本的に違う、deep diag 別 task

Plan Task 3 の Branch B (wrong register) は `../StackChan/firmware/main/hal/drivers/FTServo_Arduino/SCSCL.h` を grep する手順含む。

### HITL (Task 24)
operator 必須。Task 24 を dispatch する前に user に「実機の前にスタンバイ可能か?」確認してから rake task 起動。自動 dispatch しない。

## Mac BLE 経由検証時の注意

- Mac CoreBluetooth は GATT 0 services を永続キャッシュする (`feedback_mac_corebluetooth_gatt_cache_trap`)。詰まったら iPhone nRF Connect で並行検証
- device name は scan response から取る、discoverServices(nil) は 0x1800/0x1801 を必ず除外 (`feedback_apple_corebluetooth_gap_gatt_filter`)
- claude 自身が rb-corebluetooth-mac で scan/connect/write 可能、iPhone 依頼で人間に手間取らせない (`feedback_claude_can_do_mac_ble_scan`)

## 関連 memory (claude auto-memory)

主要参照 memory (`~/.claude/projects/-Users-bash-dev-src-github-com-bash0C7-stackchan-picoruby/memory/`):

- `feedback_servo_absolute_pos_is_core` — 本質は BLE 経由絶対位置制御、Face は装飾
- `project_actual_unknown_signals_manual_cal` — `unknown` は operator 介入 signal
- `project_ble_phase3_btstack_starve_finding` — cold-boot 後 sleep_ms 3000 必須
- `project_design_d_app_side_and_skills` — Face/Dispatcher は application.rb、FrameParser のみ firmware
- `feedback_picoruby_uart_on_device_api` — `:ESP32_UART1` / write は String only / read は positional / readpartial
- `feedback_new_gem_needs_r2p2_setup` — build_config 変更時は r2p2:setup フル必須
- `project_py32_init_puts_required` — application.rb PY32 init region の 5 puts 削除禁止
- `feedback_local_commit_autonomy_bash0c7_only` — bash0C7/* repo はローカル commit user 確認不要

## Skills 推奨

- **`superpowers:subagent-driven-development`** — メインの実装 skill (user 確定)
- `superpowers:test-driven-development` — 各 host TDD task で
- `superpowers:verification-before-completion` — task 完了主張前に
- `superpowers:systematic-debugging` — Task 3 の hypothesis 探索で
- `reference-first-debug` — Task 3 Branch B (SCSCL.h 照合) で
- `stackchan-device-iterate` — Task 2 / Task 15 / 各 Phase の device 検証
- `stackchan-device-build-flash` — application.rb 以外を変更した時のみ (scservo mrbgem 変更時は build_flash 必要)
- `stackchan-device-boot-verify` — Task 15
- `stackchan-device-face-verify` — Task 6 face_closed.sha256 lock 後の HITL
- `stackchan-device-cold-recovery` / `full-rebuild` — 失敗 escalation

## Git 状態 (本セッション終了時点)

- Branch: `feat/servo-tuning-and-test-fix`
- Working tree: clean (このハンドオフファイル commit 前)
- 直近 commit graph (新→旧):
  ```
  bf842b6 docs(plan): cold-boot redesign implementation plan
  ba521e5 docs(spec): cold-boot torque-off + normalized protocol design
  3767000 docs(handoff): next-session handoff for cold-boot redesign continuation
  1d28632 docs(handoff): mark Task 4 superseded by new cold-boot+normalized-protocol design
  ```
- Origin: `github.com/bash0C7/stackchan-picoruby` (ローカル commit autonomy 適用、push は user 指示で)

## Out of scope (次セッションでも対象外)

- PRESENT_LOAD / PRESENT_MOVING (level 2 read) は read_pos 解決後の future evolution
- detail frame 完全自動化 (numerical assertion) は read_pos 解決時のみ
- calibration の persistent storage (個体ごとの raw zero flash 保存) は別 spec
- BLE pairing / authentication は変更なし、open NUS のまま

## Quick start 1 行 (次セッション)

```
plan の Phase 1 Task 1 を subagent-driven-development で開始してくれ
```

これで main は `superpowers:subagent-driven-development` skill を invoke、plan を read、Task 1 を最初の subagent に dispatch する流れ。
