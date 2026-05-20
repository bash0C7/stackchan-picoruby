# Manual Calibration CLI Design

**Date:** 2026-05-21
**Builds on:** `2026-05-21-cold-boot-torque-off-and-normalized-protocol-design.md` (BLE direction-key protocol、`<torque:on/off>` / `<selftest:run>` 等の system-key 規約はそこから継承)
**Driver:** `handoff-2026-05-21-task15-blocker.md` — cold-boot で torque-OFF が実機で engage しないため、operator が BLE 経由で torque-off → 物理アライン → torque-on を行う運用に確定。本 spec はその BLE 操作フローと、SERVO 個体校正 (raw zero anchor) を 1 つの CLI `calibrate` に統合する。

## 動機

1. **日常運用**: cold-boot torque-OFF は best-effort (engage しないハードウェアあり)。電源投入後 servo torque ON のまま起動するため、operator が PC から BLE 経由で `<torque:off>` → 頭部を手で正面に整列 → `<torque:on>` を毎回行う必要がある。現状これは 2 つの CLI invocation (`torque off` → 手で操作 → `torque on`) で、整列中の停止指示も無い。
2. **アンカー再校正**: 個体毎に SCS servo の raw zero がズレる。`SERVO_YAW_ZERO=460` / `SERVO_PITCH_ZERO=620` / `YAW_RANGE_RAW=50` / `PITCH_RANGE_RAW=30` (application.rb StackchanApp::Head) は Phase B 時の汎用デフォルト。実機固有の正面 raw 位置を取得して定数を更新する手段が無い。
3. **Task 24 HITL 5 位置目視** (DoD #10) は人間 Y/N 判定のみで、数値 anchor 取得は手作業 (boot log grep) になっていた。

本 CLI は **(1) 操作フロー** と **(2) anchor 取得** を統合し、操作員の同じ 5 位置物理整列の中で必要な raw 値を sampling し、application.rb に paste 可能な ruby 定数ブロックを出力する。

## Section 1: 操作フロー 2 系統

### 系統 A: 日常起動 (align-only)

電源投入毎の起動手順:

```
$ bundle exec exe/stackchan-ble-control calibrate --align-only
[connect] StackChan-PicoRuby
[1/3] sending <torque:off>...
       ACK ✓ (Face::Closed displayed)
[2/3] Align head to FORWARD (yaw center, pitch center).
       Press Enter when aligned (Ctrl-C to abort)...
[3/3] sending <torque:on>...
       ACK ✓ (Face::Neutral displayed)
[done] Ready for operation.
```

exit code 0 でシェルに戻る。 anchor 数値は **取得しない** (頻繁実行を想定、UART round-trip 削減)。

### 系統 B: アンカー再校正 (full, 5-pose)

個体差で正面が物理的にズレたとき / 初回 deploy 直後 / RANGE が窮屈または広すぎる感じたとき:

```
$ bundle exec exe/stackchan-ble-control calibrate
[connect] StackChan-PicoRuby
[1/6] sending <torque:off>... ACK ✓
[2/6] Align head to FORWARD (yaw center, pitch center).
       Press Enter when aligned... <Enter>
       reading raw position (3 samples)... yaw_raw=485 pitch_raw=628 ✓
[3/6] Rotate head to STACKCHAN-LEFT MAX (operator's right side).
       Press Enter... <Enter>
       reading... yaw_raw=530 ✓
[4/6] Rotate head to STACKCHAN-RIGHT MAX (operator's left side).
       Press Enter... <Enter>
       reading... yaw_raw=440 ✓
[5/6] Tilt head UP MAX. Press Enter... <Enter>
       reading... pitch_raw=660 ✓
[6/6] Re-align to FORWARD for verification. Press Enter... <Enter>
       reading... yaw_raw=486 pitch_raw=628 ✓ (Δyaw=1, Δpitch=0 within ±3)

╭─ Calibration result ─────────────╮
│ FORWARD:    yaw=485 pitch=628    │
│ LEFT-MAX:   yaw=530   (+45)      │
│ RIGHT-MAX:  yaw=440   (-45)      │
│ UP-MAX:     pitch=660 (+32)      │
│ FWD-VERIFY: yaw=486 pitch=628 ✓ │
╰──────────────────────────────────╯

Suggested constants (paste into mrbgems/picoruby-stackchan-protocol/examples/application.rb StackchanApp::Head):

    SERVO_YAW_ZERO   = 485
    SERVO_PITCH_ZERO = 628
    YAW_RANGE_RAW    = 45   # min(|L-Z|, |R-Z|) = min(45, 45)
    PITCH_RANGE_RAW  = 32   # |U-Z| = 32

Then redeploy: /stackchan-device-iterate
```

最後に `<torque:on>` は **送らない**。なぜなら redeploy 後に新 constants で正面が再定義されるため、torque-on は redeploy 後の cold-boot 直後 `--align-only` で行う想定。`--engage-torque` flag を立てれば最後に torque-on も送る (現セッションで動作確認したい場合用)。

## Section 2: BLE protocol extension

新 frame 1 つ追加。

### Frame syntax 追加

| key | 値 | 用途 | sub-system |
|---|---|---|---|
| `read` | `pos` | 現在の raw servo position を読む (rare event、calibrate workflow 専用) | system |

既存 frame は変更なし。`<read:pos>` は full-word key 命名規則 (`torque` / `selftest` と同列) に従う。

### Dispatcher 新 handler

`StackchanApp::Dispatcher#handle` に分岐追加:

```ruby
return handle_read_pos(frame) if frame.key?("read")
```

`handle_read_pos`:

```ruby
def handle_read_pos(frame)
  unless frame["read"] == "pos"
    @stdout.write(ERROR_FRAME)
    return
  end
  if @head.nil?
    @stdout.write(ERROR_FRAME)
    return
  end
  @stdout.write(ACK_FRAME)
  actual = @head.read_actual
  yaw_raw   = actual[:yaw]
  pitch_raw = actual[:pitch]
  yaw_part   = yaw_raw.nil?   ? "yaw_raw:unknown"   : "yaw_raw:#{yaw_raw}"
  pitch_part = pitch_raw.nil? ? "pitch_raw:unknown" : "pitch_raw:#{pitch_raw}"
  @stdout.write("<#{yaw_part},#{pitch_part}>\n")
end
```

`Head#read_actual` は既に存在 (`{ yaw: raw_or_nil, pitch: raw_or_nil }`)、変更なし。

### 既存 detail frame との差別化

| 状況 | detail frame |
|---|---|
| servo command 後 (`<YL:N>` 等) | `<YL_actual:N,PU_actual:M>` (normalized magnitude、既存維持) |
| `<read:pos>` 後 | `<yaw_raw:N,pitch_raw:M>` (raw 値、新規) |
| 失敗時 | 対応する `unknown` parts |

両 detail とも 1 行 1 frame、newline 終端。calibrate CLI は `yaw_raw:` prefix で raw detail を判別。

### ERROR ケース

- `<read:unknown_value>` → ERROR ACK (`?\n`)
- `@head=nil` → ERROR ACK (servo unavailable)

## Section 3: CLI surface

既存 `exe/stackchan-ble-control` に `calibrate` subcommand を追加。

### Synopsis

```
stackchan-ble-control calibrate [--align-only] [--samples N] [--format FORMAT]
                                [--engage-torque] [--no-torque-toggle]
                                [--device NAME] [--name-prefix PREFIX]
```

### Flags

| flag | 既定 | 説明 |
|---|---|---|
| `--align-only` | off | 系統 A モード (raw 読み skip、torque off → align → torque on のみ) |
| `--samples N` | 3 | 各 pose で `<read:pos>` を N 回送って中央値を採用。1 で single-shot |
| `--format FORMAT` | `ruby` | 出力形式: `ruby` / `json` / `env` (`SERVO_YAW_ZERO=485` 等 shell 形式) |
| `--engage-torque` | off | 系統 B 最終に `<torque:on>` を送る (現セッションでテストしたい場合) |
| `--no-torque-toggle` | off | torque off / on を CLI 側で送らない (operator が外から制御済の場合) |
| `--device NAME` / `--name-prefix PREFIX` | env / `nil` | 既存 BLE オプション継承 |

`--align-only` と `--engage-torque` は両立可 (align-only 時は最後に torque on を必ず送るので redundant だがエラーにしない)。
`--no-torque-toggle` と他 torque-flag の組合せは「torque-toggle skip」を優先 (operator 明示 override)。

### Exit codes (既存 enum 拡張)

| code | constant | 意味 |
|---|---|---|
| 0 | `EXIT_OK` | success (既存) |
| 2 | `EXIT_ADAPTER` | BLE adapter 異常 (既存) |
| 3 | `EXIT_TIMEOUT` | ACK timeout (既存) |
| 4 | `EXIT_CONNECTION` | connect 失敗 (既存) |
| 5 | `EXIT_ASSERTION` | device-side ERROR ACK (既存) |
| 6 | `EXIT_CALIBRATION_NEEDED` | `yaw_raw:unknown` / `pitch_raw:unknown` 返却 = device-side read_pos 失敗 (既存定数、新規 use-case) |
| 7 | `EXIT_CALIBRATION_INCOMPLETE` | operator が Ctrl-C で中断 / verify pose で許容ズレ超過 (新規) |
| 9 | `EXIT_UNCAT` | uncaught (既存) |

`EXIT_CALIBRATION_INCOMPLETE` は CLI が detect、`<torque:on>` を送らずに exit (servo は torque-off のまま) → operator は次セッションで再試行か手動 redeploy。

### 出力形式 (`--format` バリエーション)

**ruby** (default):
```
SERVO_YAW_ZERO   = 485
SERVO_PITCH_ZERO = 628
YAW_RANGE_RAW    = 45
PITCH_RANGE_RAW  = 32
```

**json**:
```json
{"servo_yaw_zero":485,"servo_pitch_zero":628,"yaw_range_raw":45,"pitch_range_raw":32,"forward_verify":{"yaw_delta":1,"pitch_delta":0}}
```

**env** (shell-source 可):
```
SERVO_YAW_ZERO=485
SERVO_PITCH_ZERO=628
YAW_RANGE_RAW=45
PITCH_RANGE_RAW=32
```

## Section 4: anchor 計算ルール

5 pose の raw 値から定数を導く規則:

```
SERVO_YAW_ZERO   = forward.yaw_raw                        # FORWARD pose の median
SERVO_PITCH_ZERO = forward.pitch_raw
YAW_RANGE_RAW    = min(|left_max.yaw_raw - ZERO|,
                       |right_max.yaw_raw - ZERO|)        # 左右非対称時は狭い側で安全側
PITCH_RANGE_RAW  = |up_max.pitch_raw - SERVO_PITCH_ZERO|
```

### Verify pose tolerance

FORWARD verify pose は再度物理整列して raw 取得、最初の FORWARD と比較:

- |Δyaw| ≤ 3 AND |Δpitch| ≤ 3 → ✓ PASS
- 超過 → ⚠ WARN 表示、ただし exit code 0 で続行 (operator 判断で paste / 再 calibrate)
- |Δyaw| > 10 OR |Δpitch| > 10 → ✗ FAIL、`EXIT_CALIBRATION_INCOMPLETE` (7) で abort

tolerance 値 (3 / 10) は実装フェーズで実機 noise を見て微調整可、まず仮置き。

### 左右対称性チェック

`||left_max.yaw - ZERO| - |right_max.yaw - ZERO||` > 10 → ⚠ WARN (個体差 / 物理障害物の可能性を operator に通知)、続行可。

### Multi-sample median

`--samples N` 指定時、各 pose で N 回 `<read:pos>` を送る (間 50ms sleep)、N 値の median を採用。N=3 default。`unknown` が混じった場合は **その pose の sample を全捨て** → `EXIT_CALIBRATION_NEEDED` (6) で abort。

## Section 5: 実装範囲

| Path | 変更 |
|---|---|
| `mrbgems/picoruby-stackchan-protocol/examples/application.rb` | `Dispatcher#handle` に `<read:pos>` 分岐、`handle_read_pos` 実装 |
| `mrbgems/picoruby-stackchan-protocol/test/test_dispatcher_frame_contract.rb` | `<read:pos>` PASS / ERROR / `unknown` 経路の host test 追加 |
| `pc/stackchan-ble-client/lib/stackchan_ble_client/send_builder.rb` | `#read_pos` method 追加 (encode `<read:pos>`) |
| `pc/stackchan-ble-client/lib/stackchan_ble_client/frame_codec.rb` | `encode_read_pos` 追加、raw detail parser (`yaw_raw:N` pattern) 追加 |
| `pc/stackchan-ble-client/lib/stackchan_ble_client/client.rb` | `servo_frame?` と並列に `read_pos_frame?` を追加 (`<read:pos>` も detail frame を伴う) |
| `pc/stackchan-ble-client/exe/stackchan-ble-control` | `calibrate` subcommand 追加、flag parser、5-pose workflow、出力 formatter |
| `pc/stackchan-ble-client/test/client_test.rb` | mock transport で `<read:pos>` round-trip test |
| `pc/stackchan-ble-client/test/send_builder_test.rb` | `s.read_pos` frame encode test |
| `pc/stackchan-ble-client/test/frame_codec_test.rb` | raw detail parse test |
| `Rakefile` | `r2p2:ble_calibration_smoke` task (CLI 単体動作確認用、HITL は別途) |
| `CLAUDE.md` | "BLE servo control protocol" セクションに `<read:pos>` + `calibrate` subcommand 行追加 |
| `docs/superpowers/specs/2026-05-21-cold-boot-torque-off-and-normalized-protocol-design.md` | Out-of-scope セクションから "read raw position" 言及を移し、Section 2 frame table に `<read:pos>` 追加 (cross-reference 本 spec) |

## Section 6: テスト戦略

### Host test (CRuby + test-unit)

- `<read:pos>` PASS (head 初期化済) → ACK + `<yaw_raw:N,pitch_raw:M>` 出力
- `<read:pos>` head=nil → ERROR
- `<read:unknown>` → ERROR
- `<read:pos>` head.read_actual = `{yaw: nil, pitch: 628}` → ACK + `<yaw_raw:unknown,pitch_raw:628>`
- ble-client side: `s.read_pos.to_frames` = `["<read:pos>\n"]`
- ble-client: `<read:pos>` 送信 → mock transport が `<yaw_raw:485,pitch_raw:628>` 返す → `client.last_detail_frame` で取得可

### CLI integration test (mock transport)

`calibrate` subcommand の 5 step を mock で scripted 化:

1. mock client が `<torque:off>` ACK → `<read:pos>` ACK + raw 485/628 → `<read:pos>` ACK + raw 530/628 → ... 順に返す
2. CLI stdout に paste 用 ruby block が出力されるか assert
3. exit code 0
4. `--samples 3` で各 pose に 3 回 `<read:pos>` が送信されることを assert (mock の call count check)
5. `unknown` を 1 pose で返す → exit 6
6. verify pose で yaw_raw=520 (Δ35 超過) を返す → exit 7

### HITL (Task 24 と合流)

`stackchan-ble-control calibrate` を実機で実行、operator が 5 pose 物理整列、出力 constants が DoD #10 の HITL 5 位置検証と整合するか目視。Plan で Task 24 を本 CLI 実行で置き換える。

## Section 7: Definition of Done

| # | 項目 | 検証手段 |
|--:|---|---|
| 1 | `<read:pos>` host test PASS (3 経路: success / head=nil / unknown 部分返却) | `rake test` |
| 2 | `<read:unknown_value>` で ERROR | host test |
| 3 | ble-client `s.read_pos` で `<read:pos>\n` frame encode | host test |
| 4 | `client.send { \|s\| s.read_pos }` で detail frame に `yaw_raw:` 含まれる | host test (mock transport) |
| 5 | `stackchan-ble-control calibrate --align-only` 実機: torque off → Enter → torque on で Face::Closed → Face::Neutral 遷移 | HITL + boot log |
| 6 | `stackchan-ble-control calibrate` 実機 5-pose で paste 可能な ruby block 出力 | HITL |
| 7 | 出力された constants を application.rb に paste → `/stackchan-device-iterate` → `<YL:0,PU:0>` で物理正面、`<YL:100>` で物理左端 | HITL |
| 8 | `--format json` / `--format env` の出力形式 sanity | CLI test |
| 9 | `--samples 3` で `<read:pos>` 3 回送信、median 採用 (mock で sample 値が 482/485/487 なら median 485) | CLI test |
| 10 | verify pose Δ > 10 で exit 7、Δ ≤ 3 で ✓、3 < Δ ≤ 10 で WARN 続行 | CLI test |
| 11 | unknown 返却で exit 6 | CLI test |
| 12 | Ctrl-C 中断で exit 7 (および torque-off のまま留置、torque-on 送らない) | HITL + signal test |
| 13 | CLAUDE.md / 既存 spec doc の cross-reference 更新済 | grep + diff |

## Out of scope

- **on-device persistent storage of calibration values** — 個体 raw zero を flash に保存する話は別 spec。本 CLI は CRuby 側で paste 可能テキスト出力までで止める。理由: deploy パイプライン (rake r2p2:upload_appmrb) と整合させるべき、application.rb compile-time 定数で十分頻度低い
- **自動 application.rb 書き換え** — `sed` / `ruby -i` で paste 化は技術的に可能だが、誤書き換え事故 (vendor mrbgem dir 巻き込み / commit せず lost 等) を避けるため operator 介在を残す。出力テキストを `pbcopy` する程度の補助 flag は将来検討
- **Bluetooth pairing / authentication** — 既存 open NUS 維持
- **pitch-down 整列** — protocol 不可、ハード制約。calibrate workflow も pitch-down pose は要求しない
- **cold-boot torque-OFF を engaged で動かす** — Task 15 blocker (handoff-2026-05-21-task15-blocker) は本 CLI で解決せず、cold-boot 時 torque-ON で start するという hardware 仕様を受け入れる。本 CLI が毎セッション torque-off → align → torque-on の運用 cost を吸収する

## 関連 memory

- `feedback_servo_absolute_pos_is_core` — stackchan の本質は BLE 経由 servo 絶対位置制御
- `project_actual_unknown_signals_manual_cal` — `unknown` は operator 介入 signal
- `project_read_pos_branch_a_finding` — multi-turn raw position の解釈、Task 24 anchor 再校正で SERVO_*_ZERO 更新の前提
- `feedback_local_commit_autonomy_bash0c7_only` — bash0C7 origin local commit autonomy

## 関連 spec / handoff

- `docs/superpowers/specs/2026-05-21-cold-boot-torque-off-and-normalized-protocol-design.md` (本 spec の母体)
- `docs/superpowers/handoff-2026-05-21-task15-blocker.md` (本 spec の駆動理由)
- `docs/superpowers/specs/2026-05-19-phase-b-servo-design.md` (SERVO_*_ZERO / RANGE_RAW の元定義、superseded by 2026-05-21)
