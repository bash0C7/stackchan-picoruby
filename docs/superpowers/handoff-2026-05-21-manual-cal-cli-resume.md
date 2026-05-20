# Handoff 2026-05-21 (manual-cal-cli-resume): plan 確定、Phase 1 から subagent-driven 実行

## TL;DR for next session

Manual calibration CLI の **spec + plan 両方 commit 済**。次セッションは **`superpowers:subagent-driven-development` で Phase 1 Task 1 から開始**。コード未着手、全 25 task が plan に bite-size で書かれている。

## Resume trigger

USB 繋ぎ直して、次のいずれかで起動:
- 「manual cal CLI Phase 1 から start」
- 「calibrate plan 実行」
- 「stackchan plan の続き」
- 「subagent-driven で plan 実行」

## Branch state

- Branch: `feat/servo-tuning-and-test-fix`
- HEAD: `43d2772` (docs(plan): manual calibration CLI implementation plan)
- Working tree: clean
- 直近 3 commit:
  ```
  43d2772 docs(plan): manual calibration CLI implementation plan (2026-05-21)
  51cc4a8 docs(spec): manual calibration CLI design (2026-05-21)
  31f020d docs(handoff): Task 15 blocker — cold-boot torque-OFF not engaging
  ```

## 一次資料 (必ず読む)

| Doc | 役割 |
|---|---|
| `docs/superpowers/specs/2026-05-21-manual-calibration-cli-design.md` | 設計 spec (commit 51cc4a8)。DoD 13 項目はここ |
| `docs/superpowers/plans/2026-05-21-manual-calibration-cli-plan.md` | 実装 plan (commit 43d2772)。Task 1-25 が bite-size TDD で書かれている |
| `docs/superpowers/handoff-2026-05-21-task15-blocker.md` | この plan を作った直接の理由 (cold-boot torque-OFF 実機 NG → BLE manual cal fallback 確定) |

## 実行方式 (確定済)

**`superpowers:subagent-driven-development`** を使う。User の選択:

- Phase 1 Task 1 から順番に subagent dispatch
- 各 task で implementer subagent → spec-compliance reviewer → code-quality reviewer の 2 段 review
- 同セッション継続、per-task pause なし (auto mode)
- 最後 (Task 25 後) に final code-reviewer subagent で entire branch review

skill のドキュメントは plugin 配下: `~/.claude/plugins/cache/claude-plugins-official/superpowers/5.1.0/skills/subagent-driven-development/`

## Plan structure (要約、詳細は plan file)

| Phase | Tasks | 内容 | host test 含む |
|---|---|---|---|
| 1 | 1-4 | device 側 `<read:pos>` dispatcher handler + 4 host test + commit | ✓ |
| 2 | 5-8 | ble-client (FrameCodec / SendBuilder / Client detail drain) + host test + commit | ✓ |
| 3 | 9-18 | calibration.rb module (median / anchor / verify / format / sample_pose / 2 つの run_* workflow) + CLI 配線 + commit | ✓ (`calibration_test.rb` 新規) |
| 4 | 19-22 | Rakefile (`r2p2:ble_calibration_smoke`) + CLAUDE.md + cold-boot spec cross-ref + commit | — |
| HITL | 23 | 実機 calibrate --align-only → 5-pose → constants paste → redeploy → 物理動作確認 → commit | — |
| 完了 | 24-25 | 4 suite 全 host test + handoff doc 最終更新 + PR open | ✓ |

合計 25 task、bite-size (各 2-5 分目安)。

## 実行前の pre-flight

次セッション開始時に確認:

1. `git status` → working tree clean、branch = `feat/servo-tuning-and-test-fix`、HEAD = `43d2772`
2. USB 繋がってる、`ls /dev/cu.usbmodem*` で device 見える
3. `rake r2p2:monitor` が走ってない (CDC byte 競合回避、各 device skill が冒頭で guard するが念のため)
4. Phase 1 / 2 / 3 序盤は **host test のみで device 不要**。Task 17 末の smoke check と Task 19 以降で device が要る

## subagent-driven 進行のコツ (本 plan 固有)

- **Phase 1 Task 1** から開始、Plan の `Task N` セクションを **完全テキスト** で implementer に渡す (file read を作業者にさせない、controller が抽出する)
- 各 task は **TDD red-green-commit** が 3-5 step で書かれてる、implementer が勝手に scope 広げないように strict spec compliance review で押さえる
- **Task 4 / 8 / 18 / 22 / 23 / 25 は commit task**: implementer ではなく直接 main controller (claude opus) が general-purpose subagent に `git add ... && git commit` を投げる (per `~/dev/src/CLAUDE.md` git-via-subagent rule)
- **Task 23 (HITL) は claude が実行不可** な部分 (operator が物理的に頭を動かす) を含む。Task 23 Step 1-2 は user に「手で頭を動かしてや」と prompt → user の出力結果を待つ pattern
- Task 24 (4 suite 全 host test) は subagent (haiku) foreground 300s timeout で投げる、per-suite pass/fail と count のみ報告させる
- Task 25 の `git push` + `gh pr create` は global CLAUDE.md の「公開 / 共有 state 変更」に該当、user 明示 OK 必要

## Memory 更新 case

実装中に新発見あれば memory 追加候補:
- `<read:pos>` 実装中の device-only quirk
- calibration.rb 設計の予期しない issue
- HITL Task 23 で raw 値が想定外範囲 (multi-turn 関連、`project_read_pos_branch_a_finding` で予告済)
- Subagent-driven flow を本 plan で実行した workflow learnings (success / failure patterns)

## 関連 memory (継承)

主要参照:
- `feedback_servo_absolute_pos_is_core` — stackchan の本質は BLE 経由絶対位置制御
- `project_actual_unknown_signals_manual_cal` — `unknown` は operator 介入 signal
- `project_read_pos_branch_a_finding` — multi-turn position の解釈、Task 23 HITL で anchor 再校正
- `project_ble_phase3_btstack_starve_finding` — cold-boot 後 sleep_ms 3000 必須
- `feedback_local_commit_autonomy_bash0c7_only` — bash0C7 origin local commit autonomy
- `feedback_main_as_orchestrator` — bisect/探索/検証は subagent dispatch、main は分岐判定と評価
- `feedback_final_review_catches_what_per_task_misses` — final code-review (Task 25 直前) skip 厳禁
- `feedback_subagent_no_code_workaround_during_verify` — verify subagent に prod code 改変禁止を明示
- `feedback_new_gem_needs_r2p2_setup` — Phase 1 で application.rb 変更のみ、新 gem 追加無し → `build_flash` 不要、`upload_appmrb` だけで OK
- `feedback_picoruby_uart_on_device_api` — UART API 触らないので非該当だが、HITL で `read_pos` 失敗時に参考になる可能性

## Out of scope (本 plan / 次セッションでも触らない)

- cold-boot torque-OFF を実機で engaged で動かす (Task 15 blocker は受け入れ、本 CLI で日常 cal cost を吸収)
- on-device persistent storage of calibration values (spec out-of-scope 確定)
- 自動 application.rb 書き換え (operator paste 介在を残す、誤書き換え事故防止)
- Bluetooth pairing / authentication
- pitch-down 整列 (hardware 制約)
- read_pos の retry policy 調整 (現状の Branch A no-op drain_echo で動く想定、HITL で raw 取れなければ別 spec)

## 直前セッションで完了済 (再着手不要)

- Phase 1-7 host complete (scervo / Face::Closed / Dispatcher / cold-boot / PC client / Rakefile / sweep)
- Task 2 device deploy + cold-boot diag capture
- Task 3 drain_echo Branch A fix (commits 1171639, 3482f39)
- Task 14 cold-boot enable_torque(false) explicit write (commit 3c93ff7) — 実機 NG だが code 残置
- 旧 Task 15 / 24 / 25 は本 plan で再定義 (Task 23 / 24 / 25 に統合)
- spec doc 51cc4a8 / plan doc 43d2772 commit 済

## Quick context recovery

次セッション冒頭で claude が読むべき最小 path:

```
1. このファイル (manual-cal-cli-resume) を先頭から末尾まで
2. docs/superpowers/plans/2026-05-21-manual-calibration-cli-plan.md (1429 lines)
3. docs/superpowers/specs/2026-05-21-manual-calibration-cli-design.md (parallel に)
4. handoff-2026-05-21-task15-blocker.md (driver 経緯、抜粋でも OK)
5. MEMORY.md の自動コンテキスト (常時 load)
```

これだけ読めば Phase 1 Task 1 から走り出せる。
