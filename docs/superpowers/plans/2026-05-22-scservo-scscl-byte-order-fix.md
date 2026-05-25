# picoruby-scservo: SCSCL byte order fix — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** picoruby-scservo の wire byte order を M5 StackChan の SCSCL servo spec (big-endian / End=1) に合わせ、host test と device 上 read/write の両方を valid 値で動かせるようにする。

**Architecture:** `encode_signed` (pos) + `encode_unsigned` (time/speed) + `decode_signed` (read_pos) の 3 関数を **削除し、単一の `encode_word` / `decode_word` に統合**。SCSCL big-endian (`[hi, lo]` wire 順) + unsigned u16 only に統一。call site (`write_pos`, `read_pos_once`) を新 helper 経由に書き換え、host test の byte 期待値も SCSCL spec で書き直す。

**Tech Stack:** PicoRuby (mrbgem `picoruby-scservo`), Ruby (test-unit, FakeUART host stub), CRuby test runner via `bundle exec rake test`.

**Spec:** `docs/superpowers/specs/2026-05-22-scservo-scscl-byte-order-design.md`

**Branch:** `fix/scservo-scscl-byte-order` (既に切り替え済み)

---

## File Structure

- Modify: `mrbgems/picoruby-scservo/mrblib/scservo.rb`
  - 削除: `encode_signed` (現在 :237-245)
  - 削除: `encode_unsigned` (現在 :230-233)
  - 削除: `decode_signed` (現在 :248-254)
  - 追加: `encode_word(v)` — SCSCL big-endian `[hi, lo]` (unsigned u16)
  - 追加: `decode_word(hi, lo)` — SCSCL big-endian unsigned u16
  - 修正: `write_pos` (:41-50) 内 `pos_enc / time_enc / speed_enc` を `encode_word` 経由に統一
  - 修正: `read_pos_once` (:134) を `decode_word(data.bytes[0], data.bytes[1])` に統一

- Modify: `test/scservo_test.rb`
  - 削除: `test_write_pos_signed_position_uses_sign_bit_high_byte` (sign-bit spec 廃止)
  - 削除: `test_read_pos_decodes_negative` (signed return 廃止)
  - 書き換え (byte 順 + 必要なら checksum): `test_write_pos_emits_correct_packet`, `test_write_pos_with_zero_time_and_speed_means_max_speed`, `test_read_pos_returns_parsed_position`
  - 追加: `test_encode_decode_word_round_trip_scscl_big_endian` (新規 byte order 規約 lock)
  - 変更なし: `test_initializes_with_uart_and_id`, `test_read_pos_emits_request_packet` (request packet は word encoding 非依存), `test_read_pos_returns_nil_on_timeout`, その他 timeout / id / checksum 系

---

## Task 1: 新 helper `encode_word` / `decode_word` 追加 + 規約 lock test

**Files:**
- Modify: `mrbgems/picoruby-scservo/mrblib/scservo.rb` (add new private methods, do NOT yet remove old)
- Modify: `test/scservo_test.rb` (append new test)

- [ ] **Step 1: failing test を書く (round-trip + 具体 byte 順 assert)**

`test/scservo_test.rb` の `class SCServoTest` 内に追加:

```ruby
  def test_encode_decode_word_round_trip_scscl_big_endian
    servo = SCServo.new(FakeUART.new, id: 1)
    # Round trip across the unsigned u16 domain.
    [0, 1, 255, 256, 500, 1023, 1024, 2048, 4095, 32768, 65535].each do |v|
      enc = servo.send(:encode_word, v)
      assert_equal 2, enc.length, "encode_word(#{v}) length"
      assert_equal v, servo.send(:decode_word, enc[0], enc[1]),
                   "round-trip mismatch for #{v}"
    end
    # SCSCL End=1: high byte goes on the wire first.
    assert_equal [0x01, 0xF4], servo.send(:encode_word, 500),
                 "encode_word(500) must be big-endian [hi, lo]"
    assert_equal 500, servo.send(:decode_word, 0x01, 0xF4),
                 "decode_word must treat first arg as high byte"
  end
```

- [ ] **Step 2: test fails の確認**

Run: `bundle exec rake test TEST=test/scservo_test.rb 2>&1 | tail -20`

Expected: `NoMethodError: undefined method 'encode_word'` (helpers がまだ存在しないため)

- [ ] **Step 3: minimal helper を追加 (旧 helper はそのまま残す)**

`mrbgems/picoruby-scservo/mrblib/scservo.rb` の `decode_signed` 定義 (現 248-254 行) の **直後・class の最後の `end` の直前** に挿入。Edit ターゲット文字列:

old (current end of class):
```ruby
  def decode_signed(lo, hi)
    if (hi & 0x80) != 0
      -(((hi & 0x7F) << 8) | lo)
    else
      ((hi & 0x7F) << 8) | lo
    end
  end
end
```

new:
```ruby
  def decode_signed(lo, hi)
    if (hi & 0x80) != 0
      -(((hi & 0x7F) << 8) | lo)
    else
      ((hi & 0x7F) << 8) | lo
    end
  end

  # SCSCL wire encoding: SCS::Host2SCS with End=1 (SCS.cpp:33-42 + SCSCL.cpp:12).
  # Returns [hi, lo] for big-endian transmission; unsigned u16 only.
  # Position is 0-4095, time/speed are unsigned milliseconds / units.
  def encode_word(v)
    v &= 0xFFFF
    [(v >> 8) & 0xFF, v & 0xFF]
  end

  # SCSCL wire decoding: SCS::SCS2Host with End=1 (SCS.cpp:46-58).
  # Args are in wire order (first byte received = hi).
  def decode_word(hi, lo)
    ((hi & 0xFF) << 8) | (lo & 0xFF)
  end
end
```

(末尾の `end` は class 終端。インデントなしの行で 1 つだけ。)

- [ ] **Step 4: test passing の確認**

Run: `bundle exec rake test TEST=test/scservo_test.rb 2>&1 | tail -20`

Expected: 全 test PASS (新規 `test_encode_decode_word_round_trip_scscl_big_endian` 含む)。他既存 test は触ってないので変化なし。

- [ ] **Step 5: commit**

```bash
git add mrbgems/picoruby-scservo/mrblib/scservo.rb test/scservo_test.rb
git commit -m "feat(scservo): add encode_word/decode_word for SCSCL big-endian wire

New helpers express the SCSCL End=1 spec directly: unsigned u16,
[hi, lo] on the wire. Old encode_signed/encode_unsigned/decode_signed
remain in place for now; call sites migrate in subsequent commits.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 2: `write_pos` を `encode_word` に移行、write 系 test を SCSCL spec に書き換え

**Files:**
- Modify: `mrbgems/picoruby-scservo/mrblib/scservo.rb` (write_pos 内 3 箇所、:42-44)
- Modify: `test/scservo_test.rb` (2 test 書き換え + 1 test 削除)

- [ ] **Step 1: 既存 write 系 test を SCSCL spec に書き換え + 削除 (この時点で test は fail する想定)**

`test/scservo_test.rb` の以下 3 test を編集/削除:

**`test_write_pos_emits_correct_packet` を以下に置換** (現 11-22 行):

```ruby
  def test_write_pos_emits_correct_packet
    uart = FakeUART.new
    servo = SCServo.new(uart, id: 1)
    servo.write_pos(500, time_ms: 1000, speed: 0)
    # SCSCL big-endian (End=1):
    # pos=500=0x01F4 -> [0x01, 0xF4], time=1000=0x03E8 -> [0x03, 0xE8],
    # speed=0 -> [0x00, 0x00].
    # checksum = ~(1+9+3+0x2A+0x01+0xF4+0x03+0xE8+0+0) & 0xFF
    #         = ~(1+9+3+42+1+244+3+232+0+0) & 0xFF
    #         = ~0x17 & 0xFF = 0xE8
    expected = [0xFF, 0xFF, 0x01, 0x09, 0x03, 0x2A,
                0x01, 0xF4, 0x03, 0xE8, 0x00, 0x00, 0xE8]
    assert_equal expected, uart.writes.first
  end
```

**`test_write_pos_with_zero_time_and_speed_means_max_speed` を以下に置換** (現 24-34 行):

```ruby
  def test_write_pos_with_zero_time_and_speed_means_max_speed
    uart = FakeUART.new
    servo = SCServo.new(uart, id: 2)
    servo.write_pos(300, time_ms: 0, speed: 0)
    # SCSCL big-endian: pos=300=0x012C -> [0x01, 0x2C], time/speed 0
    # sum = 2+9+3+0x2A+0x01+0x2C+0+0+0+0 = 2+9+3+42+1+44 = 101 = 0x65
    # checksum = ~0x65 & 0xFF = 0x9A
    expected = [0xFF, 0xFF, 0x02, 0x09, 0x03, 0x2A,
                0x01, 0x2C, 0x00, 0x00, 0x00, 0x00, 0x9A]
    assert_equal expected, uart.writes.first
  end
```

**`test_write_pos_signed_position_uses_sign_bit_high_byte` 全削除** (現 36-45 行):

このテストごと削除する。SCSCL spec は unsigned 0-4095 のみで sign-bit 表現を持たない。

- [ ] **Step 2: write test の fail を確認**

Run: `bundle exec rake test TEST=test/scservo_test.rb 2>&1 | tail -30`

Expected: `test_write_pos_emits_correct_packet` と `test_write_pos_with_zero_time_and_speed_means_max_speed` が assertion failure (write_pos が旧 `encode_signed`/`encode_unsigned` 経由で little-endian bytes を出すため)。`test_encode_decode_word_round_trip_scscl_big_endian` は PASS のまま。

- [ ] **Step 3: `write_pos` を `encode_word` に移行**

`mrbgems/picoruby-scservo/mrblib/scservo.rb` の write_pos (現 41-50 行) を以下に置換:

```ruby
  def write_pos(pos, time_ms: 0, speed: 0)
    pos_enc   = encode_word(pos)
    time_enc  = encode_word(time_ms)
    speed_enc = encode_word(speed)
    data = [REG_GOAL_POS_L,
            pos_enc[0],   pos_enc[1],
            time_enc[0],  time_enc[1],
            speed_enc[0], speed_enc[1]]
    gen_write(data)
  end
```

- [ ] **Step 4: write test の pass を確認**

Run: `bundle exec rake test TEST=test/scservo_test.rb 2>&1 | tail -20`

Expected: 全 scservo test PASS (除外: read 系 test は次 Task で扱うので変更なし、`test_read_pos_returns_parsed_position` は旧 `decode_signed` のままなので依然 PASS)。

- [ ] **Step 5: commit**

```bash
git add mrbgems/picoruby-scservo/mrblib/scservo.rb test/scservo_test.rb
git commit -m "fix(scservo): migrate write_pos to SCSCL big-endian wire (encode_word)

pos / time / speed all use encode_word now. Tests rewritten with
SCSCL spec expected bytes. test_write_pos_signed_position_uses_sign_
bit_high_byte deleted (SCSCL spec is unsigned 0-4095, sign-bit
representation does not apply).

Spec: docs/superpowers/specs/2026-05-22-scservo-scscl-byte-order-design.md

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 3: `read_pos_once` を `decode_word` に移行、read 系 test を SCSCL spec に書き換え

**Files:**
- Modify: `mrbgems/picoruby-scservo/mrblib/scservo.rb` (read_pos_once :134)
- Modify: `test/scservo_test.rb` (1 test 書き換え + 1 test 削除 + 1 method docstring 更新)

- [ ] **Step 1: 既存 read 系 test を SCSCL spec に書き換え + 削除 (test は fail する想定)**

`test/scservo_test.rb` の以下 2 test を編集/削除:

**`test_read_pos_returns_parsed_position` を以下に置換** (現 59-65 行):

```ruby
  def test_read_pos_returns_parsed_position
    uart = FakeUART.new
    # SCSCL big-endian: pos=500=0x01F4 -> data bytes [0x01, 0xF4]
    # checksum = ~(1+4+0+0x01+0xF4) & 0xFF = ~(1+4+0+1+244) & 0xFF
    #         = ~0xFA & 0xFF = 0x05
    uart.read_queue << { bytes: [0xFF, 0xFF, 0x01, 0x04, 0x00, 0x01, 0xF4, 0x05] }
    servo = SCServo.new(uart, id: 1)
    assert_equal 500, servo.read_pos
  end
```

**`test_read_pos_decodes_negative` 全削除** (現 67-75 行):

このテストごと削除。SCSCL spec は unsigned 0-4095 のみ。

- [ ] **Step 2: read test の fail を確認**

Run: `bundle exec rake test TEST=test/scservo_test.rb 2>&1 | tail -30`

Expected: `test_read_pos_returns_parsed_position` が assertion failure。新 response bytes `[0x01, 0xF4]` を旧 `decode_signed(lo=0x01, hi=0xF4)` で解釈すると hi MSB set → `-(((0xF4 & 0x7F) << 8) | 0x01)` = -29697 が返る (期待 500 と不一致)。

- [ ] **Step 3: `read_pos_once` を `decode_word` に移行**

`mrbgems/picoruby-scservo/mrblib/scservo.rb` :134 行 を以下に置換:

```ruby
    decode_word(data.bytes[0], data.bytes[1])
```

(引数順注意: SCSCL wire では byte[0] が hi、byte[1] が lo)

加えて、:105-107 行付近の `read_pos_once` doc コメントを更新:

```ruby
  # SCSCL::ReadPos single attempt. Used by read_pos retry wrapper.
  # Returns unsigned position (0-4095) on success, nil on any failure
  # (timeout, id mismatch, length mismatch, checksum mismatch).
  def read_pos_once
```

(旧コメントは "signed position" だった)

- [ ] **Step 4: read test の pass を確認**

Run: `bundle exec rake test TEST=test/scservo_test.rb 2>&1 | tail -20`

Expected: 全 scservo test PASS。

- [ ] **Step 5: commit**

```bash
git add mrbgems/picoruby-scservo/mrblib/scservo.rb test/scservo_test.rb
git commit -m "fix(scservo): migrate read_pos_once to SCSCL big-endian decode_word

decode_word(data.bytes[0], data.bytes[1]) treats first byte as
high (SCSCL End=1 spec). Test response bytes rewritten with
big-endian pos=500. test_read_pos_decodes_negative deleted
(SCSCL spec is unsigned 0-4095).

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 4: dead code (`encode_signed` / `encode_unsigned` / `decode_signed`) 削除 + full suite verify

**Files:**
- Modify: `mrbgems/picoruby-scservo/mrblib/scservo.rb` (3 method 削除 + 周辺コメント整理)

- [ ] **Step 1: dead code 削除前 sanity check (失敗するなら順序 issue)**

Run: `grep -rn "encode_signed\|encode_unsigned\|decode_signed" mrbgems/picoruby-scservo/ test/scservo_test.rb`

Expected: 定義 3 つ (scservo.rb) のみ。call site / test 参照 が残ってたら **Task 1-3 のどこかが未完** で停止し再確認。

- [ ] **Step 2: 3 method を削除**

`mrbgems/picoruby-scservo/mrblib/scservo.rb` から 3 method 全体 (コメント含む) を削除する。Edit 対象 (旧 method block):

old:
```ruby
  # SCS::Host2SCS for big-endian word writes (SCS.cpp:33-42 with End=1).
  # Returns [low_byte, high_byte] regardless of internal storage order;
  # used for time / speed which are unsigned 16-bit. End=1 is the SCSCL
  # default (SCSCL::SCSCL ctor sets End=1).
  def encode_unsigned(v)
    v &= 0xFFFF
    [v & 0xFF, (v >> 8) & 0xFF]
  end

  # SCS sign-magnitude 16-bit encoding (used for goal position).
  # The high byte's MSB is the sign bit; the low 15 bits hold magnitude.
  def encode_signed(v)
    if v < 0
      mag = (-v) & 0x7FFF
      [mag & 0xFF, ((mag >> 8) & 0x7F) | 0x80]
    else
      mag = v & 0x7FFF
      [mag & 0xFF, (mag >> 8) & 0x7F]
    end
  end

  # Inverse of encode_signed for ReadPos return.
  def decode_signed(lo, hi)
    if (hi & 0x80) != 0
      -(((hi & 0x7F) << 8) | lo)
    else
      ((hi & 0x7F) << 8) | lo
    end
  end

```

new: (空文字列、上記 block 全体を削除)

`encode_word` / `decode_word` は Task 1 で同 class 内に追加済みなので残る。

- [ ] **Step 3: scservo test の pass を確認 (削除した method が dead だった証拠)**

Run: `bundle exec rake test TEST=test/scservo_test.rb 2>&1 | tail -20`

Expected: 全 scservo test PASS。

- [ ] **Step 4: full host test suite で regression が無いことを確認**

このプロジェクトの host test 実行は subagent (general-purpose, haiku) 経由が規律 (CLAUDE.md `~/dev/src/CLAUDE.md` Test Execution Delegation)。subagent dispatch:

> "Run `bundle exec rake test` in the foreground with 180000ms timeout from repo root `/Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby`. Tee stdout+stderr into `/tmp/stackchan-picoruby-debug/scservo-fix-full-test.log`. Report only: total tests, pass count, fail count, error count. Under 80 words."

Expected: 全 test PASS、failure / error 0。`test/scservo_test.rb` の round-trip + 書き換え 3 test + 既存変更なし test、`test/dispatcher_servo_test.rb` / `head_test.rb` / `dispatcher_test.rb` 等、box-isolated runner (rake test_isolated) は別 Rakefile タスクなのでこの Step では verify せず、Task 5 で実機 verify 前に一度確認。

- [ ] **Step 5: commit**

```bash
git add mrbgems/picoruby-scservo/mrblib/scservo.rb
git commit -m "refactor(scservo): remove dead encode_signed/encode_unsigned/decode_signed

Migrations in earlier commits moved all call sites to encode_word /
decode_word. The signed/unsigned variants used little-endian byte order
incompatible with SCSCL End=1 spec and are no longer reachable.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 5: 実機 verify (firmware build + flash + read:pos probe)

**Files:** (no code changes — verification only)

- [ ] **Step 1: firmware rebuild (mrbgem 変更を flash に反映)**

このプロジェクトの規律 (CLAUDE.md): rake は subagent (haiku) 経由 foreground 起動。`/stackchan-device-build-flash` skill を invoke (内部で `rake r2p2:build_flash` を subagent 600000ms で実行)。

Expected: build success + flash success。CoreS3 が cold-boot を開始。

- [ ] **Step 2: cold-recovery + redeploy (storage wipe + application.rb upload + reset)**

`/stackchan-device-cold-recovery` skill を invoke (chain: wipe → upload_appmrb (default = examples/application.rb) → reset)。

Expected: 全 step success。cold-boot 完了 (torque OFF + Face::Closed)。

- [ ] **Step 3: `<read:pos>` probe で valid 値を確認**

repo root から:

```bash
cd pc/stackchan-ble-client && bundle exec ruby -Ilib -rstackchan_ble_client -e '
c = StackchanBleClient::Client.new(device_name: "ignored", name_prefix: "StackChan", ack_timeout: 5.0)
c.connect
puts "[probe] 3x <read:pos>"
3.times do |i|
  c.raw_send("<read:pos>\n")
  puts "  [#{i+1}] #{c.last_detail_frame.inspect}"
  sleep 0.5
end
c.disconnect rescue nil
'
```

Expected: `<yaw_raw:N,pitch_raw:M>` の **N, M は 0-4095 範囲内**。前回壊れ値だった `-26883 / -11779` が出ない。garbage 値の root cause analysis では yaw=1001 / pitch=942 付近を予測。

**fail 時**: predicted 0-4095 範囲外なら spec の前提 (P1: SCSCL servos / P2: position mode) を再検証。`fix/scservo-scscl-byte-order` branch のまま停止し、原因切り分けに戻る (本 plan の Task 4 までは host test が green なので code 変更を revert せず、HW assumption の再調査に移る)。

- [ ] **Step 4: status report**

実機 probe 結果と次 step (HITL calibration via Task 23 → application.rb の `SERVO_*_ZERO` 更新) を 1-3 行で report。本 plan の Task はここで終了 (Task 23 以降は前 plan の HITL session)。

---

## Self-Review

**1. Spec coverage**: spec 「修正対象」「修正対象外」「After-fix workflow」「Risks」を 1:1 で task に mapping 済み。HITL calibration (spec workflow step 5-8) は前 plan の Task 23 として参照のみで本 plan の scope 外。

**2. Placeholder scan**: TBD / TODO ゼロ。全 step に具体的 code / command / 期待出力あり。

**3. Type consistency**: `encode_word(v) → [hi, lo]`、`decode_word(hi, lo) → u16` の signature が Task 1/2/3/4 で一貫。call site `data.bytes[0]` を hi、`[1]` を lo として渡す指示が `read_pos_once` 更新 (Task 3) と round-trip test (Task 1) で一致。

**4. Ambiguity check**: Task 1 step 3 と Task 4 step 2 で「insert / delete の Edit ターゲット文字列」を old/new block 形式で明示するよう修正済み。Task 4 step 4 の subagent dispatch 指示は CLAUDE.md `Test Execution Delegation` 規律に従う具体 prompt を明示済み。
