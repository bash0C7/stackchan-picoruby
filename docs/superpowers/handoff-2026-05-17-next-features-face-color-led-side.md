# Next features handoff (2026-05-17): face / color / LED side

Phase 3 (BLE NUS control + Mac client + blink + cold-boot/BTstack starve fix) が完了し、main HEAD は merge commit `bc5180e` + README polish 連発 (現在 11 commits ahead of origin/main、push 待ち)。本 doc は **次セッションで着手する追加機能 3 つ** の設計叩き台。

## Scope

- **(A)** Face pattern 拡張: 既存 4 表情 (Neutral / Smile / Joy / Surprised) + blink 専用 Closed の上に、追加表情 (Angry / Sad / Wink / Sleepy / Heart 等) を足す
- **(B)** Color pattern 拡張: 現状の R/G/B 3 値 + mode 4 種 (solid / blink / breathing / off) に、preset (happy / calm / angry / sad) や mood palette、表情との連動を入れる
- **(C)** LED side (left/right) を **Stack-chan 視点** で扱う — 現状の SIDE 仕様は実機未検証の draft assumption、まず視点を確定させる

並行で進められるが、(C) は実機検証で 1 段階完結する小タスクなので最初に潰すのがおすすめ。

## (A) Face pattern 拡張

### 現状

- `mrbgems/picoruby-stackchan-protocol/mrblib/stackchan_protocol.rb`:
  - `Face::Base` (draw_eyes + draw_mouth + 全画面 fill)
  - `Face::Neutral / Smile / Joy / Surprised` — `Base` 継承、`DELTA_Y` だけ override
  - `Face::Closed` — `draw_eyes` を horizontal line 描画に override + `draw` を eye-only update に override
- `mrbgems/picoruby-stackchan-protocol/mrblib/stackchan_protocol/dispatcher.rb`:
  - `FACE_TABLE = { "0" => Neutral, "1" => Smile, "2" => Joy, "3" => Surprised }`
  - `handle_face`: `face_class.new.draw(@display)` + `@current_face_class = face_class` (blink restore で使う)

### 追加候補

| キー | クラス案 | 表現 |
|---|---|---|
| `4` | `Face::Angry` | 眉ハの字下げ + 口つの口 |
| `5` | `Face::Sad` | 眉ハの字上げ + 口角下げ |
| `6` | `Face::Wink` | 片目だけ Closed の line、もう片方は open ellipse |
| `7` | `Face::Sleepy` | 両目を半開きの楕円 (高さ縮小) |
| `8` | `Face::Heart` | 目をハート型 |

### 設計メモ

- `Face::Base` には既に `clear_eye_region` / `redraw_eyes_open` ヘルパーがある — wink などは eye-only update で書ける
- mouth の表情差分は Face クラスごとに `draw_mouth` override で吸収するのが既存パターン (Surprised が前例)
- 眉描画は現在ない → `Face::Base` に `draw_brows(display)` no-op を足し、必要な subclass で override
- ble-client CLI (`--face` option) と dispatcher の FACE_TABLE のキーを揃える必要

### 検証手順

- 追加した Face クラスを smoke で 1 つずつ通す (`FACE=angry`, `FACE=sad`, etc.)
- 既存 Step 5 (4 face × 4 mode × 3 side smoke) を拡張 face 込みでカバレッジ確認

## (B) Color pattern 拡張

### 現状

- `dispatcher.rb#handle_led`:
  - frame 受信: `R` / `G` / `B` (0-255 to_i) + `M` (mode: s/b/p/o) + `S` (side: L/R/B)
  - `@led.animate_side(side, r, g, b, mode)` 呼び出し
- `Animator` (`mrbgems/picoruby-stackchan-led/mrblib/stackchan_led/animator.rb`):
  - mode: `:solid` / `:blink` (500ms half-period) / `:breathing` (LUT [0..100], 250ms step) / `:off`
- ble-client CLI: `--led "<color> <mode>"` (例 `--led "red blink"`)。color 名 → RGB の解決はおそらく client 側

### 検討項目

1. **Preset name サポート**: `--led-preset happy` で warm yellow solid、`--led-preset calm` で cool blue breathing 等
2. **Mood palette**: face と LED を連動 (`FACE=joy` → preset auto `happy`)。1 frame で同期送る or 2 frame に分ける判断
3. **Gradient / Rainbow**: 時間変化色 (新 mode `:rainbow`)。`Animator` の tick に追加
4. **frame protocol 拡張案**:
   - `P=happy` (Color Preset key) を新設 → device 側で RGB に解決 (lookup table on-device)
   - もしくは preset は **client 側で展開** → device protocol は変更なし (シンプル)
   - シンプル案推奨: protocol 互換性壊さない

### 設計メモ

- client 側で preset → RGB 展開する場合、CLI は `--led-preset` を新 option として追加するだけ
- mood palette (face + LED 連動) も client 側で組み立て可能 → 1 connect で 2 frame 送る
- Animator 拡張 (rainbow 等) は device 側の mode 追加 = protocol の `M` key 値追加 (例 `r`)

## (C) LED side を Stack-chan 視点で確定

### 現状 (**draft assumption、実機未検証**)

`mrbgems/picoruby-stackchan-led/mrblib/stackchan_led.rb:6-11`:

```ruby
# Left/right physical pixel index split (draft assumption — verify visually
# via rake r2p2:ble_control_smoke SIDE=left / SIDE=right and adjust if the
# physical wraparound differs).
LEFT_RANGE  = (0..5)
RIGHT_RANGE = (6..11)
```

つまり「pixel index 0-5 が `:left`」と決め打ちしてあるが、

- **物理的にどの位置の pixel か** (装置正面から見て左半分? 右半分? 上半分? 下半分?) — 未確認
- **「左」を誰の視点で呼ぶか** (Stack-chan vs 人間) — 未確定

ユーザ指示: **Stack-chan 視点に統一**。Stack-chan が「自分の左手側」と思う方が `:left`。

### 検証手順 (最小)

1. main の現状ビルドのまま `bundle exec rake r2p2:ble_control_smoke COLOR=red MODE=solid FACE=neutral SIDE=left` を流す
2. **人間目視**: 赤く光った 6 pixel が「Stack-chan から見て左 (= 向かい合った人間からは右)」か?
3. 一致しなければ `LEFT_RANGE` と `RIGHT_RANGE` を swap (1 行修正、1 commit)
4. `SIDE=right` でも同様に確認

### 設計判断

- device 内で Stack-chan POV を固定。protocol / CLI も Stack-chan POV 前提で記述
- README / dispatcher / animator コメントに「Stack-chan POV」を明示
- 公式 firmware (`../StackChan`) の同等部分 (LED 制御) で視点規約があるか参照しておく

### Bonus

- pixel ring の wraparound (12 pixel が物理的にどう並ぶか) も同時に確認。「上下半分」分割が必要かも

## 参考コミット (main)

- `bc5180e` Phase 3 merge (BLE control + blink + cold-boot fix)
- `2c22558` / `cd93a17` blink eye-only refactor (face 拡張時の draw pattern 参考)
- `b41c70e` Dispatcher に `current_face_class` accessor 追加 (face 拡張時にそのまま使える)

## 関連 memory

- `feedback_mac_corebluetooth_gatt_cache_trap` / `feedback_mac_scan_truncates_epoch` — Mac BLE 開発時の制約
- `feedback_main_as_orchestrator` — subagent dispatch + 吟味のリズム
- `feedback_subagent_no_code_workaround_during_verify` — verify subagent には改変禁止を明示
- `project_ble_phase3_btstack_starve_finding` — cold-boot 後 `sleep_ms 3000` は production application で外さない

## 次セッション 1 発目の動き案

1. (C) を実機 smoke 1 発で確定 → swap PR 1 commit
2. (A) Angry / Sad の 2 face を追加 PR (FACE_TABLE 拡張 + CLI 拡張 + smoke)
3. (B) preset を client 側で展開する PR (protocol 互換性保持)

おすすめは上記順 (依存少ない順)。各 PR 独立で merge 可能。
