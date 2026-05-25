# Handoff: picoruby-scservo SCSCL byte order fix — 完了 + 次フェーズ HITL calibration

Date: 2026-05-22
Branch: `feat/servo-tuning-and-test-fix` @ `912d363` (merge commit、fix branch は削除済)
Repo: `/Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby`

## 状態語

**完了** — plan の全 5 task + final-review fixup 完了、`fix/scservo-scscl-byte-order`
を非-ff (`--no-ff`) で親 branch `feat/servo-tuning-and-test-fix` へ merge 済。
fix branch 削除済 (commit history は merge commit `912d363` に保存)。

## 今 session の成果

| Item | 値 |
|---|---|
| Plan | `docs/superpowers/plans/2026-05-22-scservo-scscl-byte-order-fix.md` |
| Spec | `docs/superpowers/specs/2026-05-22-scservo-scscl-byte-order-design.md` |
| Fix commits | 5 (`fbd28e0` → `6010b24` → `042b00b` → `9264e34` → `78b87ef`) |
| Merge commit | `912d363` (--no-ff) |
| host test | 70 tests / 124 assertions / 0 failures / 0 errors / 5 pre-existing omissions |
| 実機 `<read:pos>` probe | yaw_raw=**472**, pitch_raw=**630** (3 連続同値、valid 0-4095 unsigned) |
| 修正前 garbage | yaw_raw=-26883, pitch_raw=-11779 (signed garbage) |

byte-order fix が wire 上で確認できた → fix proven on real hardware。

## アーキテクチャ要約 (再確認用)

- `encode_word(v) → [hi, lo]` (SCSCL big-endian, unsigned u16) を `write_pos` で pos/time/speed
  3 つに統一適用
- `decode_word(hi, lo) → u16` を `read_pos_once` で `data.bytes[0]=hi, [1]=lo` に適用
- 旧 `encode_signed` / `encode_unsigned` / `decode_signed` は完全削除
- test fixture も全部 SCSCL big-endian `[0x01, 0xF4]` に flip

## 次フェーズ: HITL calibration (前 plan の Task 23)

実機で valid raw 値が読めるようになったので、操縦正面アラインと SERVO_*_ZERO / RANGE_RAW
の anchor recal を実行する。

1. **Daily startup**: `bundle exec exe/stackchan-ble-control --name-prefix StackChan calibrate --align-only`
   - cold-boot torque OFF → operator が頭を物理正面に → torque ON
2. **5-pose anchor recal**:
   `bundle exec exe/stackchan-ble-control --name-prefix StackChan calibrate [--samples N] [--format ruby|json|env]`
   - 5 pose で sample 取得 → `SERVO_*_ZERO` と `RANGE_RAW` 出力
3. **application.rb 更新**: `mrbgems/picoruby-stackchan-protocol/examples/application.rb` の Head class 定数を
   出力された値で書き換え
4. **deploy**: `/stackchan-device-iterate` (upload application.rb + reset + boot verify)
5. **HITL visual check**: 0° / 45° / 90° で実物の頭の向きを確認、操縦目的座標と一致するか

Spec: `docs/superpowers/specs/2026-05-21-manual-calibration-cli-design.md`
Plan: `docs/superpowers/plans/2026-05-21-manual-calibration-cli-implementation.md` (Task 23 周辺)

## 環境状態 (重要、次 session 開始時に確認)

### USB / device
- 現状 USB 接続済 (`/dev/cu.usbmodem1101`)。次 session で device 触る場合は `ls /dev/cu.usbmodem*` で確認
- device 現状: cold-boot 直後、torque OFF、Face::Closed、`<read:pos>` で valid 値返す

### ESP-IDF Python venv 状態 (今 session で reset した)

| Aspect | 状態 |
|---|---|
| 現存 venv | `idf5.4_py3.12_env` (今 session 作成), `idf5.4_py3.14_env` (古い), `idf5.4_py3.9_env` (古い) |
| build が使う | `idf5.4_py3.12_env` (mise python 3.12 経由) |
| install.sh 実行時の注意 | **`bash -c` で実行** (`bash -lc` は homebrew python3.14 を拾って 3.14 venv を作る → mismatch) |
| sdkconfig 状態 | esp32s3 + CoreS3 + BTstack fragments 全 merge 済 |

次 session で build が「ESP-IDF Python virtual environment not found」や「Python version mismatch」
を吐いたら、本 session の経過 (下記) を見て同手順:

1. `bash -c '. ~/esp/esp-idf/install.sh esp32s3'` (login shell NG)
2. `bash -c 'cd ~/dev/src/github.com/bash0C7/R2P2-ESP32 && . ~/esp/esp-idf/export.sh && idf.py fullclean'`
3. `bundle exec rake r2p2:setup` (mruby host rebuild + set-target esp32s3 を 1 chain で)
4. `bundle exec rake r2p2:build_flash`

これ書いてる時点で 1〜3 は終わってる、次 session で再度の build_flash は不要 (firmware は最新の fix 込み)。

### BLE name prefix
`StackChan` (advertising as `StackChan-PicoRuby`)、CLI には `--name-prefix StackChan` で渡す。

## Git 状態

- Current branch: `feat/servo-tuning-and-test-fix` @ `912d363` (clean)
- `fix/scservo-scscl-byte-order` branch: 削除済
- main との差分: 親 branch の全 commit (本 fix 含む) が未 merge — main 統合は別途判断
- `git revert 912d363` で本 fix 全体を 1 commit で巻き戻し可能 (revert path)

## このセッションで学んだ env 知見 (CLAUDE.md 候補)

- **ESP-IDF install.sh は `bash -c` で実行** (login shell `-l` は PATH 順序が変わって homebrew python 拾う)
- **`idf.py fullclean` は target を default esp32 に戻す** → 直後に `idf.py set-target esp32s3` 必須
  (これは既に CLAUDE.md `## R2P2-ESP32 ビルド・flash フロー` に記載済、再確認)
- **venv mismatch (sdkconfig が 3.14、shell が 3.12 等) で `idf.py clean` 拒否される** → `fullclean` で sdkconfig 自体 wipe

## 終了

本 plan の scope はここで終了。次 plan (HITL calibration) は前 spec を参照、本 fix が前提
として valid 値を read できる状態を提供したことを confirm 済。
