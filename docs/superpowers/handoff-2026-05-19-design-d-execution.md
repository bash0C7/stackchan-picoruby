# Design D 実装ハンドオフ (2026-05-19)

**Spec:** `docs/superpowers/specs/2026-05-19-app-side-business-logic-and-skills.md` (commit `5ec4a68`)

**Plan:** `docs/superpowers/plans/2026-05-19-app-side-business-logic-and-skills.md` (commit `1fe7bc9`)

**Execution skill:** `superpowers:subagent-driven-development`

**Resume trigger:** user が「Design D 実装を始めて」「subagent-driven で plan を実行して」等を言ったら、subagent-driven-development を起動して plan を Task 1 Step 1.1 から進める。

## なぜこの handoff があるか

2026-05-19 セッションで Phase A HITL を再開しようとしたところ、device が `Guru Meditation Error: InstrFetchProhibited` の起動ループに陥った。crash dump を addr2line で解決した結果、`/home/app.rb` を on-device で mruby codegen する経路 (`new_lit_str` / `codegen` / `gen_values`) で main task stack overflow していたと判明。

これを受けて user と brainstorming → Design D に到達:

1. Face DSL + Dispatcher (StackChan business logic) を application.rb に inline、`StackchanApp` namespace 化
2. firmware (picoruby-stackchan-protocol mrbgem) は `FrameParser` のみ残す
3. `.rb` 直送り path (`r2p2:upload SRC=...rb DST=/home/app.rb`) を削除、`upload_mrb` (DST 必須) と `upload_appmrb` (autostart 固定) のみ
4. 都度 memory recall でやってた deploy 操作を `stackchan-device-*` skill 群 (10 atomic + 5 chain) に標準化、11 個に slash alias

Phase A HITL (Sad/Angry 視認 + golden 登録) は Design D 実装 Plan の Task 14-16 に取り込み済み。**`handoff-2026-05-18-phase-a-hitl-resume.md` は superseded** (Task 14-15 が代替)。

## 開始位置

Plan の **Task 1 Step 1.1** (project root に `Gemfile` 設置) から順次。

Tasks 1-13 は host のみで完結 (device 不要)。Task 14 で初めて device 上げる (`/stackchan-device-full-rebuild` → `/stackchan-device-boot-verify` → HITL #0 Neutral 視認)。

## 重要な前提

- device は **crash ループ状態のまま放置で OK**。Plan の Task 14 で `/stackchan-device-full-rebuild` が走り、firmware も application も同時に作り直すので、ここまで device に触る必要なし。
- Plan の Task 7 で mrbgem を shrink する。`picogem_init.c` の symbol 削除が走るので、Task 14 で `build_flash` が link 失敗する可能性あり。失敗時は `/stackchan-device-setup` 経由で全部再生成。
- Task 5 の golden SHA 移行: `canonical_dump` を mrbgem 版から byte-for-byte 維持しないと既存 4 golden (neutral/smile/joy/surprised) が FAIL する。Plan に詳細あり。
- Phase A の sad/angry golden 期待 SHA は memory `project_kawaii_ai_phase_a_code_complete.md` に記録済み (`c4e04b97...` / `b8fe1cb5...`) ── HITL OK なら register でこの SHA が出るはず。

## 既存 task list の扱い

今 session で TaskCreate した #1〜#13 のうち、Phase A HITL 関連 (#1-#8、#10) は Plan の Task 14-16 が代替するので **削除して新 plan の TaskCreate に切り替える** べき。recovery 関連 (#9, #12) と debug task (#11) は完了済み。

`subagent-driven-development` skill 起動時に既存 task は cleanup、Plan の Task 1-16 を新規 TaskCreate して進める。

## 次セッションでのトリガー文

user が「**Design D の実装を始めて**」または「**plan を subagent-driven で進めて**」と言ったら:

1. `superpowers:subagent-driven-development` skill 起動
2. 既存 task list cleanup (この handoff の前提知識を踏まえ、stale task を deleted に)
3. Plan ファイル読み込み、Task 1〜16 を TaskCreate
4. Task 1 Step 1.1 から fresh subagent dispatch 開始
