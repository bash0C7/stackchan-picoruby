# Phase B Task 10 進行状況 / hardware recovery 必要 (2026-05-19)

## 概要

Phase B 全体 (subagent-driven plan, 16 task) のうち Task 1-9 全完了、Task 10 (firmware full rebuild + boot-verify + boot-failure regression) で **picoruby-uart on-device API 3 件発見・修正** したが、ハード replug が必要な「device-side weird state」で boot-verify 確認まで届かず一旦切り上げ。

## どこまで進んだか

| Task | 状態 | Commit |
|---|---|---|
| 1: scservo gem scaffold | DONE | 3cb2ed6 |
| 2: write_pos packet | DONE | 66d2930 |
| 3: read_pos + timeout | DONE | eeaa5be |
| 4: enable_torque + set_mode | DONE | 29680a3 |
| 5: WritePos ACK drain | DONE | d2888d8 |
| 6: StackchanApp::Head | DONE | 0c0a8eb |
| 7: Dispatcher Y/P/V/T | DONE | 42c31e5 |
| 8: cold-boot servo init | DONE | dda8be3 |
| 9: build_config (R2P2-ESP32) | DONE | bcd14d0 (in R2P2-ESP32 repo) |
| 10: firmware rebuild + boot-verify | **partial** — fix commit 53dd264、device 状態回復必要 |
| 11-16 | pending |

Host test: 52 PASS, 0 omit (Phase A 19 + scservo 15 + Head 11 + Dispatcher servo 7)

## Task 10 で発見した 3 個の picoruby-uart on-device API gotchas

memory `feedback_picoruby_uart_on_device_api` に常備保存。要点:

1. **`unit:` symbol は `:ESP32_UART1`** — `:UART1` だと `UART_unit_name_to_unit_num` が match せず unit_num=-1 → ESP-IDF `uart_driver_install` 拒否 → `uart_event_task` の queue null で xQueueReceive assert → Guru Meditation
2. **`UART#write` は String only** — Array 渡すと `TypeError: Array cannot be converted to String`。SCServo の packet byte 配列は `packet.pack('C*')` で String 化必要
3. **`UART#read(n)` は positional 1 引数のみ、timeout_ms kwarg なし** — `readpartial(n)` を使う

3 件とも commit `53dd264 fix(scservo,app): align with picoruby-uart on-device API` で application.rb / picoruby-scservo / FakeUART / spec / plan に修正反映済。

## 現在の device 状態

何度も wipe + upload + reset を繰り返し、最新の firmware (rebuilt with new scservo Ruby) + 新 app.mrb (`:ESP32_UART1`) を deploy 完了したが、boot capture が silent (ESP-IDF bootloader output の途中で停止、`[application] boot` 以降 puts なし)。

可能性:
- USB CDC が multi-wipe で混乱した一過性の不具合 → USB physical replug で復活見込み
- PSRAM init で本当に hang (新 firmware に何か問題)、要再 build_flash + capture
- 別 root cause

**次セッションでまず試すこと (順序):**

1. **USB cable を物理的に抜き差し** (CoreS3 を一度 host から外して再接続)
2. `bin/capture-with-pty 30 /tmp/stackchan-picoruby-debug/boot-recovery.log bundle exec rake r2p2:monitor` を background 起動して boot 出力確認
3. `[application] boot` → `LCD + LED cold-boot done` → `[boot] servo init OK` (期待) が出れば fix 成功
4. もし `[boot] servo init failed: ...` なら、その error message を見て更に debug (Task 10 続行)
5. もし完全 silent なら、`/stackchan-device-full-rebuild` 一発 (10 分) で fresh state にリセット
6. 上記で boot OK 確認後、spec §5.4 の boot-failure regression test (txd_pin: 99 で意図 fail → `<ERROR:servo_unavailable>` 確認 → revert) を実行
7. それも OK なら Task 10 を completed にして Task 11 (Mac SendBuilder + FrameCodec encode_head) に進む

## 学習として MEMORY 追加済

- `feedback_picoruby_uart_on_device_api` — 3 件の API gotcha

## 関連 docs

- spec: `docs/superpowers/specs/2026-05-19-phase-b-servo-design.md`
- plan: `docs/superpowers/plans/2026-05-19-phase-b-servo.md`
- 過去 boot log: `/tmp/stackchan-picoruby-debug/boot.log` (UART panic), `boot-after-fix.log` (TypeError rescue), `boot-v2.log` (mrb_vm_exec crash), `boot-v3.log` / `boot-v5.log` (silent)

## 次セッションでの推奨フロー

`superpowers:subagent-driven-development` を続けて起動して Task 10 (上記 手順 1-6) から再開、その後 Task 11-16。Task 10 の hardware-recovery 部分以外 (Task 11 以降) は host-side 中心で進められる。
