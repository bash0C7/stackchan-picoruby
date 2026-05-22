# picoruby-scservo: SCSCL byte order fix (Design)

Date: 2026-05-22
Branch: `fix/scservo-scscl-byte-order`

## 背景

`<read:pos>` BLE frame で device から detail を取得すると、deterministic に
壊れ値が返る:

- yaw_raw = -26883 (servo 1)
- pitch_raw = -11779 (servo 2)
- torque on/off 不問、5 回連続同値、反復後も再現

加えて `<YL:0,PU:0,T:100>` 等の position コマンドで物理 head が ~180°
過剰旋回する。SCS servo 自体は通信成立しており、書き込みも反映されて
いる (ACK 受信、physical motion observed) が、目標 raw 値と実際 raw 値が
乖離。

## Root cause

picoruby-scservo (`mrbgems/picoruby-scservo/mrblib/scservo.rb`) の
`encode_signed` / `decode_signed` が wire byte order を
**little-endian** で実装している。

M5 StackChan の hardware は **SCSCL series** servo を使用しており、
SCSCL は wire 上 **big-endian (End=1)** を spec とする。

### Reference 照合

- `m5stack/StackChan/firmware/main/hal/drivers/FTServo_Arduino/src/SCS.cpp:46-58`
  `SCS2Host(DataL, DataH)`: `End==1` 分岐は `Data = (DataL << 8) | DataH` を返す
  (最初に届くバイト `DataL` を上位 8 bit として組み立て)
- 同 `:33-42` `Host2SCS(*DataL, *DataH, Data)`: `End==1` 分岐は
  `*DataL = (Data>>8)` `*DataH = (Data&0xff)` (上位を先に送る)
- `SCSCL.cpp:12` `End = 1;` — SCSCL constructor 内で確定セット
- `m5stack/StackChan/firmware/main/hal/hal_servo.cpp:16`
  `static SCSCL _scs_bus;` — 公式は SCSCL class を instantiate
- 同 `:80` `_scs_bus.WritePos(_config.id, mapped_angle, 20, 0);` —
  position mode のみで呼び出し (`SetMode` / `WheelMode` 不在)

### Garbage 値の arithmetic 検証

received data bytes = `[0x03, 0xE9]` を:

- picoruby (little-endian + sign-magnitude):
  `lo=0x03`, `hi=0xE9` (MSB set) → `-(((0xE9 & 0x7F) << 8) | 0x03)` = -26883
- SCSCL spec (big-endian unsigned):
  `(0x03 << 8) | 0xE9` = **1001** (valid 0-4095 position)

pitch bytes `[0x03, 0xAE]` も同様: `(0x03 << 8) | 0xAE` = **942** (valid)。

両 servo とも cold-boot 物理アライン直後の forward position として
plausible な値。

### Write 側も同 root cause (3 関数)

position: `encode_signed(460)` は `[0xCC, 0x01]` ([lo, hi]) を返し wire に
この順で送出。servo は最初の byte を上位 8 bit として復号: `(0xCC << 8) |
0x01` = 52225。0-4095 範囲を超過し servo は max yaw 位置にクランプ →
物理 ~180° 旋回 (= 観測された「回りすぎ」)。

time / speed: `encode_unsigned(time_ms)` も同じ little-endian `[v & 0xFF, (v
>> 8) & 0xFF]` で実装 (scservo.rb:230-233)。コメントは "big-endian word
writes (SCS.cpp:33-42 with End=1)" と書いてあるが実装と乖離。time=100ms
は wire `[0x64, 0x00]` → servo 解釈 25600ms など、time/speed も全て誤値。
ただし time=0 / speed=0 path では max-speed 制御に倒れるので観測症状は
position の clamp が支配的。

### Sign-bit logic の位置づけ

commit `eeaa5be feat(scservo): implement read_pos with sign-magnitude decode
and timeout` (2026-05-19) で `encode_signed` / `decode_signed` を意図的に
追加。著者意図は「yaw の左右を負/正 raw で表現」だが、SCSCL hardware は
unsigned 0-4095 のみ。signed 表現の責務は application 層 (Head class の
YL/YR direction key 計算) にあるべきで、wire 層に持ち込むのは誤抽象。

## Scope

### 修正対象

- `mrbgems/picoruby-scservo/mrblib/scservo.rb`
  - `encode_signed(v)` (pos 用、scservo.rb:237-245) + `encode_unsigned(v)`
    (time/speed 用、:230-233) を **削除し単一の `encode_word(v)` に統合**
    - 戻り値: `[hi, lo]` (SCSCL big-endian、wire 出順)
    - 実装: `v &= 0xFFFF; [(v >> 8) & 0xFF, v & 0xFF]`
    - sign-bit 分岐は持たない (SCSCL は unsigned u16 only)
  - `decode_signed(lo, hi)` (:248-254) を `decode_word(hi, lo)` にリネーム
    - 引数順: SCSCL wire 順 (first byte = hi, second byte = lo)
    - 戻り値: `(hi << 8) | lo` (unsigned u16)
    - sign-bit 分岐除去
  - `write_pos` 内呼び出し (`pos_enc`, `time_enc`, `speed_enc`): 3 つとも
    `encode_word` 経由に統一
  - `read_pos_once` 内呼び出し (:134): `decode_word(data.bytes[0],
    data.bytes[1])` (wire 順 = byte[0] が hi)

- `test/scservo_test.rb`
  - `test_write_pos_emits_correct_packet`: 期待 bytes と checksum を SCSCL
    spec で書き換え
  - `test_write_pos_with_zero_time_and_speed_means_max_speed`: 同上
  - `test_write_pos_signed_position_uses_sign_bit_high_byte`: 削除
  - `test_read_pos_returns_parsed_position`: response bytes 順を SCSCL spec
    に書き換え
  - `test_read_pos_decodes_negative`: 削除
  - `test_read_pos_emits_request_packet`: 変更不要 (request packet は byte
    order 非依存、payload は addr/len の 1 byte ずつ)
  - timeout / nil / id mismatch 系: 変更不要
  - 新規 1 ケース追加: `encode_word` → wire bytes → `decode_word` の round-
    trip で同値復元 (byte order 規約 lock)

### 修正対象外

- `mrbgems/picoruby-stackchan-protocol/examples/application.rb` の Head class
  (`SERVO_*_ZERO`, `RANGE_RAW`) — 値の意味は変わらない (依然として raw 0-4095
  範囲の整数)。修正後の HITL calibration で正しい zero を再確定する別タスク。
- `mrbgems/picoruby-stackchan-protocol/dispatcher` の servo math — `Head`
  symbolic 参照のみで raw 値の絶対値に依存しない (P5 verified)。
- `test/dispatcher_servo_test.rb`, `test/head_test.rb`,
  `mrbgems/picoruby-stackchan-protocol/test/test_dispatcher_frame_contract.rb`
  — FakeServo mock + `SERVO_*_ZERO` symbolic 参照、byte order 独立。

## 設計判断

### Approach A (採用) — Minimal hard-coded SCSCL

`encode_word` / `decode_word` を SCSCL big-endian にハードコード。
SCServo class は SCSCL spec 専用とし、End フラグも mode parameter も
持たせない。

不採用:

- **B (Parametric End)**: M5 reference mirror、`end_mode:` keyword で SMS_STS
  / HLSCL の同時 support。現状 SCSCL 1 種のみ運用、SMS_STS 採用予定もない。
  YAGNI 違反、未使用パス。
- **C (Mode flag constant)**: SCSCL に End=1 を内部定数として明示。B より控
  えめだが、SCServo class 名自体が SCSCL 専用と読めるので明示する価値が薄
  い。

将来 SMS_STS 等の異 endian servo を扱うときは、SCSCL 専用 class を残しつ
つ別 class (SMSSTSServo) を追加するか、A → B への incremental refactor を
行う。どちらも本修正後に検討可能。

### sign-bit 表現の application 層への移管

Wire 層 (SCSCL spec) は unsigned 0-4095 のみ。yaw の左右は application 層
(`mrbgems/picoruby-stackchan-protocol/examples/application.rb` の Head class
で SERVO_YAW_ZERO からの delta 符号で判定) で表現済み。本修正で wire 層
sign-bit を除去しても application 層に影響なし。

## After-fix workflow

1. Host test (`bundle exec rake test`) — SCSCL spec で全 green
2. Firmware rebuild (`rake r2p2:build_flash`、5-10 分、subagent foreground)
3. Cold-recovery + redeploy (`/stackchan-device-cold-recovery`)
4. probe `<read:pos>` → 0-4095 range 内の値 (1001 / 942 付近想定)
5. HITL: align-only flow で head を forward へアライン → torque ON → 再
   probe → forward zero の raw 値確定
6. HITL: 5-pose calibrate CLI → SERVO_*_ZERO / RANGE_RAW の推奨定数印字
7. `application.rb` の Head 定数更新 → `/stackchan-device-iterate`
8. HITL visual check: 0° / 45° / 90° で YL/PU magnitude が物理 angle に
   追従するか確認 (精度は coarse、margins of error 内合わせ込み)

## Risks / 未検証

- **未知 1**: SCSCL big-endian の wire byte 順は datasheet と reference の
  1:1 照合、および arithmetic 一致 (1001 / 942 が valid 範囲) で根拠強い
  が、修正実機 build → probe の最終確認まで実測未完。
- **未知 2**: 修正後の Head::RANGE_RAW スケール (現 yaw=50 / pitch=30) が、
  新 zero (~1001 / 942) を基準に ±5° / +90° を物理 angle で正しく表すか
  未確認 — HITL で margins of error (0° / 45° / 90° 粒度) 内合わせ込み。
- **既知**: 現 `application.rb` の `SERVO_*_ZERO = 460 / 620` は fix 後
  そのまま使えない可能性が高い (HITL calibration 結果で上書き)。

## Revert path

`fix/scservo-scscl-byte-order` branch 上で実装。`feat/servo-tuning-and-test-
fix` への merge 前であれば branch 削除で完全 revert。merge 後は revert
commit 1 つで scservo.rb + scservo_test.rb の変更を巻き戻し可能 (他 file
影響なし、self-contained)。
