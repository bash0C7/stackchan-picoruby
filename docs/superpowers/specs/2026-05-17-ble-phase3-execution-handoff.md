# BLE Phase 3 — Execution Handoff for Clean Session (2026-05-17)

このファイルは、**新しい Claude Code セッションで Phase 3 plan の 19 task を実装する**ための引き継ぎ。Spec / Plan は既に書き上がり commit 済み、`feature/ble-phase3-control` branch に乗っている。実装は新セッションで `superpowers:subagent-driven-development` skill 経由でやる方針。

設計検討に使った前セッションの context は捨て、このファイル + plan + spec を起点に動く。

---

## 0. 起動コピペ用 prompt

新セッションを `/Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby` で開いて、これをそのまま投げる:

> stackchan-picoruby BLE Phase 3 の実装に入る。spec と plan は書き上がってて `feature/ble-phase3-control` branch に乗ってる。
>
> まず `docs/superpowers/specs/2026-05-17-ble-phase3-execution-handoff.md` を読んで、その指示通りに進めて。引き継ぎ通り subagent-driven-development skill で 19 task を順に消化。

---

## 1. 起動直後の最初の 5 分

1. **このファイルを読む**: `docs/superpowers/specs/2026-05-17-ble-phase3-execution-handoff.md` (今これ)
2. **Plan を読む**: `docs/superpowers/plans/2026-05-17-ble-phase3-control-cli.md` (2774 行、19 task)
3. **Spec を読む**: `docs/superpowers/specs/2026-05-17-ble-phase3-control-cli-design.md` (Plan のソース)
4. **branch / 状態を確認**:
   ```bash
   cd /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby
   git status
   git log --oneline main..HEAD
   ```
   期待値: branch `feature/ble-phase3-control`、`main` から **3 commit ahead** (`36e95c0` spec / `acabbd2` simplify / `da761c2` plan)、working tree clean。
5. **`superpowers:subagent-driven-development` skill を invoke** して Plan path を渡す。skill が task-per-subagent の dispatch loop を回す。

---

## 2. 引き継ぎ時点の state スナップショット

### Repos (両 repo 同期済み)

| Repo | Branch | 状態 |
|---|---|---|
| `~/dev/src/github.com/bash0C7/stackchan-picoruby` | `feature/ble-phase3-control` | 3 commits ahead of `origin/main`、clean tree |
| `~/dev/src/github.com/bash0C7/rb-corebluetooth-mac` | `main` | up-to-date (Phase 2 PR #1 merged) |

### 既に commit 済みの artifact (`feature/ble-phase3-control` 上)

```
da761c2 docs(ble): Phase 3 implementation plan — 19-task TDD breakdown
acabbd2 docs(ble): simplify Phase 3 spec — drop backward-compat carrots
36e95c0 docs(ble): Phase 3 spec — stackchan-ble-client SDK + application.rb dispatcher
```

`main` (= `6cc2dc2`) からの差分は **doc 3 ファイルのみ**:
- `docs/superpowers/specs/2026-05-17-ble-phase3-control-cli-design.md` (新規)
- `docs/superpowers/specs/2026-05-16-ble-phase3-handoff.md` (session decisions log を追記)
- `docs/superpowers/plans/2026-05-17-ble-phase3-control-cli.md` (新規)

ソースコードは一切触ってない。Task 1 から始めれば clean start。

### Hardware state

* CoreS3 は `/dev/cu.usbmodem1101` 想定 (Rakefile で auto-detect)
* `/home/app.mrb` は **Phase 2 ble_smoke.rb の bytecode** が載っている (60s advertise 後 exit、その後 R2P2 shell prompt)
* Phase 2 build_flash 時点の `sdkconfigs/cores3` + `sdkconfigs/bt_btstack` + `sdkconfig.defaults` (16MB Flash / Quad PSRAM 8MB / BLE-only COEX disable) が flash に乗っている
* Mac CoreBluetooth permission: 前セッションの terminal app には grant 済み。**新セッションを別 terminal で開くと permission re-prompt の可能性あり** (Task 18 の E2E smoke 実行時に当たる)

### Auto-loaded memory (起動時に自動 inject される)

`~/.claude/projects/-Users-bash-dev-src-github-com-bash0C7-stackchan-picoruby/memory/MEMORY.md` 経由で以下が load される。Phase 3 で特に効いてくるものに ★ を付けた:

* ★ `feedback_apple_corebluetooth_gap_gatt_filter` — Mac CoreBluetooth は `discoverServices(nil)` で 0x1800/0x1801 を必ず除外、device name は scan response から取る
* ★ `feedback_mac_corebluetooth_gatt_cache_trap` — 0 services キャッシュ詐欺、`sudo pkill bluetoothd` で復旧
* ★ `project_picoruby_ble_heartbeat_tick_one_second` — `heartbeat_callback` は ~1s/tick (NOT 100ms)
* `project_ble_phase2_complete` — Phase 2 完了状態、本実装の前提
* `feedback_verify_at_air_interface` — device-side log だけでは RF emission 証拠にならない、外部 receiver で必ず air interface 検証
* `feedback_local_commit_autonomy_bash0c7_only` — ローカル commit は user 確認不要 (bash0C7/* repo に限る)
* `feedback_read_code_line_by_line` — SDK / vendor code を skim せず行単位で読む
* `project_mac_communication_path` — Mac↔CoreS3 通信路アーキ全体像
* `project_btstack_offspec_picoruby_ble` — BTstack は ESP-IDF サポート外、picoruby-ble fork で直す

---

## 3. 実装フロー (subagent-driven)

`superpowers:subagent-driven-development` skill の正規パターン:

1. Main session (= 新セッション、Opus) が plan を読んで task list を抽出
2. Task 1 を subagent (general-purpose, model 指定なし → デフォルトに従う) に dispatch
3. Subagent が task の Step を全部実行 (test 書く → red → 実装 → green → commit)
4. Subagent 完了 → main が結果 review (diff + 出力 + test 結果)
5. 問題なければ Task 2 へ。問題あれば fix task を挟む or 該当 task を retry
6. 全 19 task 終わったら **Task 18 の視認確認** を user に依頼 → user OK → Task 19 (README)
7. `superpowers:finishing-a-development-branch` skill で merge / PR を決定

各 task の subagent prompt は plan の該当節 (例 `## Task 3: FrameCodec...`) を **そのまま** 渡せばよい。Step が全部書いてある。

### Task ごとの所要時間目安

| Task | 種別 | 所要時間 |
|---|---|---|
| 1 | gem skeleton | 5-10 min |
| 2-7 | Mac gem 実装 (TDD) | 10-15 min × 6 = 60-90 min |
| 8-11 | uploader / Rakefile / 旧 gem 削除 | 10-15 min × 4 = 40-60 min |
| 12-14 | device LED / Dispatcher (TDD) | 10-15 min × 3 = 30-45 min |
| 15 | application.rb 新規 | 15-20 min |
| 16 | Rakefile r2p2:ble_control_smoke | 5 min |
| **17** | **R2P2 build_flash** | **5-10 min** (長時間 rake、subagent foreground, timeout 600000+) |
| 18 | E2E smoke + LEFT/RIGHT fine-tune | 15-30 min (HW 試行錯誤次第) |
| 19 | README | 5 min |

**合計目安**: 3-5 時間 (HW 触り始めるまでは ~1.5 時間で済む、それ以降は実機・user 関与)。

### Task 間で「これは設計問題」と気付いた場合

* 軽い fine-tune (例 LEFT_RANGE / RIGHT_RANGE 反転): plan の該当 task の Step 内で対応、commit を継ぎ足し
* spec を改訂すべきレベル: `superpowers:writing-skills` ではなく `superpowers:brainstorming` に立ち戻り spec doc を更新、その後 plan も更新。**ただし scope 拡大 (例: サーボを足したくなる) は user 承認を必須**

---

## 4. 留意事項 (Critical project-local rules)

### 4.1 rake は subagent foreground、1 個ずつ (CLAUDE.md project-local override)

* 全 rake 実行 (`rake test` / `rake r2p2:*` / `rake -T`) は **subagent (general-purpose, model: haiku) に foreground で 1 個だけ** 投げる。`screen -dmS` longrun pattern は使わない (本プロジェクト局所 override)
* subagent は pass/fail と test count のみ要約して返す、フルログは戻さない (main context 保護)
* 失敗時は別 subagent で detail collection
* 例外: `r2p2:setup` (今回不要のはず) / `r2p2:build_flash` (Task 17) は 5-15 分かかるので haiku subagent + **timeout 600000ms 以上** を必須指定
* 例外: デバッグ中の単発テスト (`-n test_specific`) は main の Bash 直叩き可

### 4.2 No Python (CLAUDE.md global)

uploader (`lib/deploy/picomodem.rb`) は Ruby + uart gem。**Python に書き換えない**。

### 4.3 Local commit autonomy: bash0C7/* repo に限る

`feature/ble-phase3-control` branch への commit は user 確認不要。git 操作は subagent (general-purpose or `commit-commands` skill) に委譲推奨 (main context 保護)。

**ただし以下は明示承認が必須**:
- `git push --force` (今 plan で push 自体しないが、念のため)
- `git rebase -i` を含む history rewrite
- main / origin/main への直接 push
- `feature/ble-phase3-control` 以外の branch 触り

### 4.4 Hardware ops は人間に振る (claude code Bash には TTY 無し)

| 状況 | 人間に振るアクション |
|---|---|
| Upload で `FILE_ACK got nil` 連続 | monitor 起動 → R2P2 shell → `rm /home/app.mrb` → `Ctrl-]` → claude 側 retry |
| Board silent / boot log 確実に見たい | 別ターミナルで `cd ../../bash0C7/R2P2-ESP32 && rake monitor` |
| USB device 消失 | USB 抜き挿し |
| storage 完全 wipe | BOOT 押しながら USB 挿し → download mode → flash |
| LED / LCD の物理状態 (Task 18) | 目視確認お願い、serial trace は補助 |

* `bin/capture-with-pty SECONDS LOG CMD...` で PTY 付き短時間キャプチャ可
* 軽量目的なら `cat /dev/cu.usbmodemXXXX > tmp/longrun/serial.log` を `run_in_background` で起動 → reset → log を read

### 4.5 PicoRuby compatibility

* `mrbgems/picoruby-*` 配下を編集するとき、**勝手な「禁止メソッドリスト」に頼らない**
* 不明なら `chiebukuro-mcp` の Ruby/PicoRuby ナレッジ DB に問い合わせ → 答えなければ `~/dev/src/github.com/picoruby/picoruby` を Explore subagent で確認
* Plan の Task 12 にも書いたが、`Range#each` の挙動が host CRuby と PicoRuby で差があるため `while` ループで indexed 走査する方が安全
* `defined?` / inline `rescue` / `proc` / `lambda` / `String#reverse` 等は **避ける癖** を維持 (ただし禁止リストは盲信しない)

### 4.6 Silent rescue 禁止 (CLAUDE.md project)

`rescue nil` / 空 `rescue` / `rescue => _` 全部禁止。テストコードでは `omit "reason: #{e.message}"` で skip 理由を可視化、production では re-raise / 構造化ログ / Result 型返却のいずれか。

### 4.7 上書き upload は 6 秒待ってから

`r2p2:upload` / `r2p2:upload_mrb` の連続実行は `read_exact` TIMEOUT_MS=5000ms を考慮して **6 秒以上空ける**。`r2p2:flash` 直後は **8〜12 秒待って boot 完了**。Task 16 の `r2p2:ble_control_smoke` は `AUTOSTART_WAIT=12` default にしてある。

### 4.8 mrbgem on-device require は `picoruby-` を strip した hyphen 形

例: `picoruby-stackchan-protocol` mrbgem を on-device で require する場合は `require 'stackchan-protocol'` (underscore は `LoadError`)。Plan の `application.rb` は既にこの形 (`require 'stackchan-protocol'`、`require 'stackchan-led'`)。

### 4.9 `build_config/xtensa-esp-picoruby.rb` に新 gem 行追加 → `rake r2p2:setup` 必須

Phase 3 で **新 mrbgem を足すことはない** (既存 `picoruby-stackchan-protocol` / `picoruby-stackchan-led` の中を編集するだけ) ので `r2p2:setup` は走らせなくて済むはず。**Task 17 は `r2p2:rebuild_gems` + `r2p2:build_flash` の軽量ルートで完了する想定**。

もし build で「stackchan_protocol が見つからん」「stackchan_led の新メソッドが反映されてない」等が出たら、**`r2p2:rebuild_gems` を踏んだか確認** (`libmruby.a` を rm して picoruby rake を強制再実行する)。

---

## 5. Draft assumptions (spec §11 の追跡項目)

実装中・E2E 中に検証する。問題出たら plan を fine-tune commit。

| # | 仮定 | 検証 task | 失敗時の対応 |
|---|---|---|---|
| 1 | LED 物理 index 0-5 = left / 6-11 = right | Task 18 Step 3 | LEFT_RANGE / RIGHT_RANGE 入れ替え or rotate、`mrbgems/picoruby-stackchan-led/mrblib/stackchan_led.rb` を編集して `rebuild_gems` + `build_flash` 再実行 |
| 2 | `peri.start(0)` で無限 advertise | Task 18 Step 1 (boot 後 advertise 継続するか観察) | `0xFFFFFFFF` 等 large value に置換、`application.rb` 末尾を編集 |
| 3 | AckSink queue 排出 (heartbeat 1B + can_send_now) | Task 18 Step 2 (smoke で全 ACK 受信できるか) | バッチ排出 (heartbeat で N byte まとめて push_read_value) に変更、`application.rb` の `heartbeat_callback` / `flush_one_ack` を改修 |
| 4 | `MODE_TABLE` の `:off` 実装済み | Task 18 Step 4 (mode=off で LED 消えるか) | Animator の `apply_immediately` で `:off` を確実に handle (現状は `clear` 相当) |
| 5 | corebluetooth_mac の write_without_response back-pressure | Task 18 Step 2 (4 frame 連射で全 ACK 揃うか) | `Client#send_frame` 内で write 直後に `sleep 0.05` 等の rate-limit を追加 |

---

## 6. Definition of Done (Phase 3 完了条件)

以下が全部 ✓ になったら Phase 3 完了:

1. ✓ Plan の Task 1-19 全部 commit 済み
2. ✓ `cd pc/stackchan-ble-client && bundle exec rake test` が green (全テスト pass)
3. ✓ `cd mrbgems/picoruby-stackchan-led && bundle exec rake test` が green
4. ✓ `cd mrbgems/picoruby-stackchan-protocol && bundle exec rake test` が green
5. ✓ `rake r2p2:build_flash` 通る
6. ✓ `rake r2p2:ble_control_smoke COLOR=red MODE=blink FACE=joy SIDE=both` が **exit 0** で帰る
7. ✓ **視認 (user 必須)**: LCD に joy 顔、LED ring が red blink (両側) で動いている
8. ✓ SIDE=left / SIDE=right 切替で物理的に正しい半分が点灯
9. ✓ 4 face (neutral/smile/joy/surprised) 全部 LCD に描かれる
10. ✓ mode=blink / breathing / solid / off が視覚的に区別できる
11. ✓ `pc/stackchan-protocol/` directory が存在しない、Rakefile に legacy task 残ってない
12. ✓ `feature/ble-phase3-control` branch を push、user の判断で PR open

---

## 7. 完了後 (Phase 3.5 / 次の議題への遷移)

Phase 3 完了したら `superpowers:finishing-a-development-branch` skill で merge / PR の決定。**default は PR 開いて user merge** (Phase 2 と同パターン)。

Phase 3.5 (サーボ) の準備:
* spec / plan は **本 session では作らない** (scope discipline)
* 新 brainstorming session で:
  - `picoruby-scservo` gem 新規作成 (UART 1Mbaud、GPIO 6/7、ID 1=pan / ID 2=tilt)
  - PY32 P0 で servo 電源 ON
  - protocol に S/T (pan/tilt 角度) frame key 追加
  - Dispatcher 拡張
  - Mac CLI `move` sub-command + DSL `stackchan.move(pan: deg, tilt: deg)` 追加

---

## 8. Anti-patterns / 注意 (project-specific)

* **Phase 3 scope は face + LED のみ**。サーボ / WebSocket / Web Bluetooth / per-pixel addressable LED は出てきても **絶対に Phase 3 に混ぜない** (本 session で明示 deferral 済み)
* **USB-serial CLI を残したくなる衝動に乗らない**。Plan の Task 11 で `pc/stackchan-protocol/` を消す。`stackchan-control` exe や `r2p2:send_led` task は完全廃止
* **`idf.py monitor` を Bash 直叩きしない** (TTY 無い)。HW 観察は `bin/capture-with-pty` または `cat` + `run_in_background`
* **失敗 task を黙って再試行ループしない**。CLAUDE.md global 「ロングバッチ実行パターン」と同じく、3-4 周回したら user に相談
* **commit message は English** (CLAUDE.md project)
* **`.claude/` 配下 (CLAUDE.md / skills / guides) を commit するなら必ず含める**。今回は触らない想定
* **destructive git op は明示承認が必須** (force push / reset --hard / branch -D)
* `picoruby-ble` の **on-device `require` は `ble`** (gem 名 `picoruby-ble` から `picoruby-` strip)
* **frame protocol 拡張**: spec で `L`/`F`/`R`/`G`/`B`/`S`/`M` key 確定。他 key を勝手に足さない (将来サーボ frame key は Phase 3.5 で議論)

---

## 9. Key file paths (quick reference)

| 用途 | path |
|---|---|
| 本 handoff | `docs/superpowers/specs/2026-05-17-ble-phase3-execution-handoff.md` |
| Phase 3 spec | `docs/superpowers/specs/2026-05-17-ble-phase3-control-cli-design.md` |
| Phase 3 plan | `docs/superpowers/plans/2026-05-17-ble-phase3-control-cli.md` |
| 前段 Phase 3 handoff (Phase 2 完了直後) | `docs/superpowers/specs/2026-05-16-ble-phase3-handoff.md` (Session decisions log 追記済み) |
| Phase 2 spec (参考) | `docs/superpowers/specs/2026-05-16-ble-mac-autonomous-verification-loop-design.md` |
| Project CLAUDE.md | `CLAUDE.md` |
| User-level CLAUDE.md (~/.claude/) | `/Users/bash/.claude/CLAUDE.md` |
| Dev tree CLAUDE.md | `/Users/bash/dev/src/CLAUDE.md` |
| Rakefile (Task 9/10/16 で編集) | `Rakefile` |
| 隣接 R2P2-ESP32 | `../../bash0C7/R2P2-ESP32/` |
| 隣接 rb-corebluetooth-mac (Task 1 で path 依存) | `../../bash0C7/rb-corebluetooth-mac/` |
| Memory index | `~/.claude/projects/-Users-bash-dev-src-github-com-bash0C7-stackchan-picoruby/memory/MEMORY.md` |

---

## 10. 「変な状態だな」と思ったら

新セッションを開いた時に以下のいずれかになっていたら、**まず state を確認** してから動く:

* branch が `feature/ble-phase3-control` でない → `git checkout feature/ble-phase3-control` (clean tree 前提)
* working tree が dirty → 何が変更されてるか確認、Phase 3 と無関係なら user に問い合わせ
* `main` を push 済 / merge 済 → 想定外、git log 確認、user に状況問い合わせ
* `pc/stackchan-protocol/` が既に消えている → 前セッションが Task 11 まで進んでた可能性、`git log --oneline main..HEAD` で確認、続きから再開
* `pc/stackchan-ble-client/` が既に存在 → 同上、進捗確認、続きから

要するに **git log とファイル状態を信じて、checklist (§6) と plan の commit 履歴を突き合わせて、どこから再開すべきか判断する**。

---

## 11. user 問い合わせが必要な事象

新セッションの subagent は基本独立に動くが、以下は main session が user に明示問い合わせ:

* 視認確認 (Task 18 各 step、LED 物理 left/right、face 描画、mode 切替)
* scope 拡大 (例: サーボ足したい、WebSocket 試したい)
* HW recovery 必要 (upload 詰まり、board silent、storage wipe 要)
* destructive git op (force push、history rewrite)
* PR open のタイミング・タイトル・description
* Phase 3 完了宣言 (§6 全部 ✓ になった時点)

---

以上。新セッションは §0 の prompt をコピペしてスタート。
