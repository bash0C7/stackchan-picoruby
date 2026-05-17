# application.rb Debug Trace Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** application.rb で BLE が即 stop してた問題 (`peri.start(0)` = 0ms run) を、Phase 2 で実証済みの `peri.start(60_000)` に直し、各 callback が実際に発火しとるかを debug puts で確認できる状態にする。

**Architecture:** 修正は最小スコープに限定:
1. `peri.start(0)` → `peri.start(60_000)` (Phase 2 ble_smoke.rb で実証済みの引数)
2. debug puts 追加のみ (instance state や既存ロジックの改変は禁止)

**Tech Stack:** PicoRuby (mrblib + ESP32 / R2P2 autostart), picoruby-ble (BTstack vendored), serial console.

**Scope discipline:** ユーザ指示「これ以外の変更をいれるな」に従う。以下は **対象外**:
- `peri.start` の引数を `60_000` 以外に変える / `loop` で囲む / 別 N で実測
- 既存 puts のテキスト改変、comment 更新、init ロジック改変
- Rakefile, picoruby-ble 内部, Bundler 環境 etc.

---

## Current state

Branch `feature/ble-phase3-control`、working tree:
- `application.rb` line 142: 既に `@hb_tick = 0` が混入 (前 turn でわしが書いた未承認の変更) — **revert 必須**
- `application.rb` line 146, 148: `puts "[application] initialize: super(:peripheral) entering"` / `puts "[application] initialize: super returned"` — これは debug puts なので残す
- `application.rb` line 234: `peri.start(0)` のまま (未修正)

`/tmp/boot.log` で観測済みの最終到達行: `[application] start returned — should not reach here under normal operation` → R2P2 shell。

---

## File Structure

修正ファイル 1 個のみ:
- Modify: `mrbgems/picoruby-stackchan-protocol/examples/application.rb`

新規・削除なし。

---

## Task 1: Revert `@hb_tick` (未承認混入の除去)

**Files:**
- Modify: `mrbgems/picoruby-stackchan-protocol/examples/application.rb:142`

- [ ] **Step 1: `@hb_tick = 0` 行を削除**

```ruby
@ack_queue = ""
@hb_tick = 0                  # ← この行を削除
@dispatcher = StackchanProtocol::Dispatcher.new(
```

修正後:

```ruby
@ack_queue = ""
@dispatcher = StackchanProtocol::Dispatcher.new(
```

- [ ] **Step 2: 確認**

```bash
grep -n "@hb_tick" mrbgems/picoruby-stackchan-protocol/examples/application.rb
```

Expected: 一致なし (0 行)。

---

## Task 2: `peri.start(0)` を `peri.start(60_000)` に置換

**Files:**
- Modify: `mrbgems/picoruby-stackchan-protocol/examples/application.rb:234`

- [ ] **Step 1: 引数を `60_000` に変更**

```ruby
peri.start(0)
```

を

```ruby
peri.start(60_000)
```

に置換。これ 1 行のみ。`peri.start` の前後行 (228-235) の他テキスト/コメントは触らない。

- [ ] **Step 2: 確認**

```bash
grep -n "peri.start" mrbgems/picoruby-stackchan-protocol/examples/application.rb
```

Expected: `peri.start(60_000)` の 1 行のみ表示。

---

## Task 3: heartbeat_callback / packet_callback の発火確認用 puts 追加

**Files:**
- Modify: `mrbgems/picoruby-stackchan-protocol/examples/application.rb`

目的: run loop が実際に回って callback が呼ばれてるかをログから判定可能にする。

- [ ] **Step 1: `packet_callback` 冒頭に event byte log を追加**

現状:

```ruby
def packet_callback(event_packet)
  case event_packet[0]&.ord
  when BTSTACK_EVENT_STATE
```

の `case` の直前に 1 行追加:

```ruby
def packet_callback(event_packet)
  puts "[application] pkt evt=#{event_packet[0] ? event_packet[0].ord : 'nil'}"
  case event_packet[0]&.ord
  when BTSTACK_EVENT_STATE
```

ロジックは無改変、puts だけ追加。

- [ ] **Step 2: `heartbeat_callback` 冒頭に発火 log を追加**

現状:

```ruby
def heartbeat_callback
  # NUS RX drain
  rx_data = pop_write_value(@rx_handle)
```

の `# NUS RX drain` の直前に 1 行追加:

```ruby
def heartbeat_callback
  puts "[application] heartbeat"
  # NUS RX drain
  rx_data = pop_write_value(@rx_handle)
```

ロジックは無改変、puts だけ追加。

- [ ] **Step 3: 構文チェック (host picorbc)**

```bash
PICORBC=/Users/bash/dev/src/github.com/bash0C7/R2P2-ESP32/components/picoruby-esp32/picoruby/bin/picorbc
$PICORBC -o /tmp/application.mrb mrbgems/picoruby-stackchan-protocol/examples/application.rb && ls -la /tmp/application.mrb
```

Expected: `/tmp/application.mrb` が生成される (~5-6KB)。

- [ ] **Step 4: diff 確認**

```bash
git diff mrbgems/picoruby-stackchan-protocol/examples/application.rb
```

Expected: 以下のみが差分:
- `@hb_tick = 0` 削除 (Task 1)
- `peri.start(0)` → `peri.start(60_000)` (Task 2)
- packet_callback / heartbeat_callback 冒頭の puts 追加 (Task 3 Step 1-2)

それ以外の差分があれば revert。

---

## Task 4: device に upload + reset + boot ログキャプチャ

実機操作。USB-CDC 再列挙のタイミング問題を避けるため、操作順を厳守する。

**Files:** なし (実機操作のみ)

- [ ] **Step 1: application.mrb を device に upload**

```bash
bundle exec rake r2p2:upload_mrb SRC=mrbgems/picoruby-stackchan-protocol/examples/application.rb
```

Expected: `[picomodem] DONE_ACK ok` で正常終了。失敗なら autostart が STDIN を握ってる可能性 → 人間に `rm /home/app.mrb` 依頼。

- [ ] **Step 2: serial キャプチャを background で起動 (`bin/capture-with-pty`)**

reset の前にキャプチャ走らせて、boot 出力の頭から逃さんように:

```bash
bin/capture-with-pty 75 tmp/longrun/phase3-trace.log bundle exec rake r2p2:monitor &
CAP_PID=$!
```

- [ ] **Step 3: 2 秒待って monitor が起動してから reset**

```bash
sleep 2
bundle exec rake r2p2:reset
```

- [ ] **Step 4: 70 秒待ってキャプチャ自然終了 (5s escape + ~3s init + 60s start + 余裕)**

```bash
wait $CAP_PID
```

- [ ] **Step 5: log を read して到達行を確認**

```bash
tail -120 tmp/longrun/phase3-trace.log
```

確認ポイント (期待):
- `[application] boot` — 必須 (autostart 起動確認)
- `[application] LCD + LED cold-boot done` — 必須
- `[application] BLE peripheral starting (infinite advertise)` — 必須
- `[application] initialize: super(:peripheral) entering`
- `BTstack up and running at ...`
- `[application] initialize: super returned`
- `[application] pkt evt=96` (= 0x60 BTSTACK_EVENT_STATE)
- `[application] HCI WORKING — advertising`
- `[application] heartbeat` が **複数回** (~60 回、~1s/tick)
- `[application] start returned ...` (60s 後)

期待外パターン:
- `[application] heartbeat` が 0 回 → run loop が回っていない (別仮説必要)
- `[application] pkt evt=...` が 0 回 → packet_callback が呼ばれていない
- どこかで puts が途切れて hang → そこが致命的な crash 地点

---

## Self-Review

**1. Spec coverage:**
- 「peri.start(60_000) に直す」→ Task 2 ✓
- 「debug puts でどの行まで進むか明確にする」→ Task 3 (packet/heartbeat) + 既存 super() puts ✓
- 「これ以外の変更をいれるな」→ Task 1 で未承認の @hb_tick を revert、Task 3 は puts 追加のみ ✓

**2. Placeholder scan:** 全 step に具体的なコード/コマンドあり。TBD / TODO 無し。

**3. Type consistency:** 既存メソッドのシグネチャに触れず、puts 追加のみなので型整合性問題なし。

**4. Scope guard:** Task 4 Step 4 の diff 確認で「scope 外の変更がないこと」を強制する step を入れた。

---

## Out of scope (今回触らない)

- `peri.start(60_000)` の `60_000` を変える / loop で囲む / 別の引数で実測 — Phase 2 実証外
- 既存コメントブロック (line 227-230) の更新 — 内容は古いが、変更は別 task
- Rakefile の Bundler 問題 — 別件
- LEFT/RIGHT 物理 index 検証 — advertise が立ってから
- README / handoff doc の Draft assumption #2 更新 — 検証完了後

---

## Execution

Plan saved to `docs/superpowers/plans/2026-05-17-application-debug-trace.md`. Task 1-3 は 1 ファイル小修正、Task 4 は実機操作。Inline execution (この session で順番にやる) で進める前提。
