# Handoff: picoruby-scservo SCSCL byte order fix — subagent-driven execution

Date: 2026-05-22
Branch: `fix/scservo-scscl-byte-order` (parent: `feat/servo-tuning-and-test-fix`)
Repo: `/Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby`

## 状態語

**待機** — spec + plan + revert branch 準備完了、subagent-driven 実行を次セッションで開始予定。

## 次セッションで何をするか

`superpowers:subagent-driven-development` skill を invoke して、
`docs/superpowers/plans/2026-05-22-scservo-scscl-byte-order-fix.md` の
Task 1 から順に subagent dispatch + main review で実行する。

Plan は 5 task 構成:

| Task | 内容 | 検証手段 |
|---|---|---|
| 1 | `encode_word` / `decode_word` 追加 + round-trip test | `rake test TEST=test/scservo_test.rb` |
| 2 | `write_pos` を encode_word に移行 + write 系 test 書き換え | 同上 |
| 3 | `read_pos_once` を decode_word に移行 + read 系 test 書き換え | 同上 |
| 4 | 旧 `encode_signed` / `encode_unsigned` / `decode_signed` 削除 + full host suite | `rake test` (subagent foreground) |
| 5 | 実機 verify: build_flash → cold-recovery → `<read:pos>` probe で 0-4095 範囲確認 | skill chain |

各 task は TDD (RED → GREEN → COMMIT)、task 終端で commit。Task 5 は実機
USB が繋がっている前提。

## Spec / 設計判断

- 設計 doc: `docs/superpowers/specs/2026-05-22-scservo-scscl-byte-order-design.md`
- Approach A 採用 (SCSCL hard-coded、parametric End なし、YAGNI)
- 削除対象: encode_signed (pos)、encode_unsigned (time/speed)、decode_signed (read_pos)
- 統一先: 単一 `encode_word(v)` (big-endian `[hi, lo]`) + `decode_word(hi, lo)` (unsigned u16)

## Root cause 要約 (再確認用)

picoruby-scservo の wire byte order が **little-endian** 実装 (`[lo, hi]`)。
M5 StackChan は SCSCL 系 servo (`m5stack/StackChan/firmware/main/hal/hal_servo.cpp:16 static SCSCL _scs_bus;`)、SCSCL は **big-endian (End=1)** spec (SCS.cpp:46-58 SCS2Host + SCSCL.cpp:12)。

実機 probe で得た壊れ値:
- yaw_raw=-26883 → bytes [0x03, 0xE9] を big-endian で読むと **1001** (valid)
- pitch_raw=-11779 → bytes [0x03, 0xAE] を big-endian で読むと **942** (valid)

write 側の症状「YL:0 (target raw 460) で物理 ~180° 旋回」も同 root cause:
460=[0xCC, 0x01] を servo が big-endian で 52225 と解釈 → max yaw クランプ。

## 現在の git 状態

- Working branch: `fix/scservo-scscl-byte-order` (clean)
- 親: `feat/servo-tuning-and-test-fix` @ `64e63c1`
- このブランチでの commit:
  - `f3ecdb8 docs(spec): picoruby-scservo SCSCL byte order fix design`
  - `ab371da docs(plan): picoruby-scservo SCSCL byte order fix implementation plan`
- 次セッションで Task 1 commit が予定 commit 3 番目以降

## 環境状態 (Task 5 実行時用)

- USB ケーブル接続 (前 session の続き)
- device 現状: cold-boot torque OFF + Face::Closed (最新 application.rb redeployed at this session)
- `<read:pos>` は現状 garbage 値 -26883 / -11779 を返す状態 (fix 適用前)
- BLE name prefix: "StackChan" (advertising as "StackChan-PicoRuby")

## Revert path

- Task 1-4 まで完了して問題発覚 → branch ごと drop で完全 revert
- merge 後発覚 → `git revert <merge-commit>` で巻き戻し (self-contained、他 file 影響なし)

## Task 5 後の次フェーズ (本 plan 範囲外)

実機 valid 値が確認できたら、前 plan の HITL Task 23 を実行:
- `bundle exec exe/stackchan-ble-control --name-prefix StackChan calibrate --align-only`
- 5-pose calibrate で SERVO_*_ZERO / RANGE_RAW 確定
- `application.rb` (Head class) の定数更新 → `/stackchan-device-iterate`
- HITL visual check (0° / 45° / 90°)
