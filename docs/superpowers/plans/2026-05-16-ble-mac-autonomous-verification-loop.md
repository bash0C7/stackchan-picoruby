# BLE Mac Autonomous Verification Loop Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `rake r2p2:ble_verify` 1 コマンドで CoreS3 への .mrb upload → reset → Mac 側 BLE central scan/connect/discover/read/write/subscribe → exit code で pass/fail を返す自律検証ループを完成させる。

**Architecture:** Mac 側に `pc/stackchan-protocol/exe/stackchan-ble-verify` (Ruby + rb-corebluetooth-mac gem) を新設、Rakefile に `r2p2:ble_verify` を追加して既存 `r2p2:upload_mrb` + `r2p2:reset` と連結する。検証は phase 単位で stdout に header 出力、失敗時は stderr に構造化 1 行で phase + reason + domain を出して non-zero exit。

**Tech Stack:** Ruby 4.0.3 (CRuby), Bundler, rb-corebluetooth-mac gem (Swift native ext), 既存 R2P2-ESP32 / picoruby-ble / BTstack。

**Spec:** [`docs/superpowers/specs/2026-05-16-ble-mac-autonomous-verification-loop-design.md`](../specs/2026-05-16-ble-mac-autonomous-verification-loop-design.md)

---

## File Structure

**Create:**
- `pc/stackchan-protocol/exe/stackchan-ble-verify` — 単一 CLI ファイル。phase ごとに上から下に流れる直列フロー。

**Modify:**
- `pc/stackchan-protocol/Gemfile` — `rb-corebluetooth-mac` を `path:` で追加。
- `pc/stackchan-protocol/Gemfile.lock` — `bundle install` で自動更新 (手動編集しない)。
- `Rakefile` — `r2p2:ble_verify` task 追加。

CLI は ~150 行の単一ファイル、phase の単純な直列フロー、ロジックの再利用がほぼ無いため分割しない (YAGNI)。将来 sub-command 化したくなったら、その時点で `Cli::Verify` 等にクラス抽出する。

**Device preconditions for runtime tests:**
- 多くの task は実機 CoreS3 が advertise 状態である必要がある (state_check 以降)。各 task に prep コマンドを inline で書く。
- 最初に 1 回だけ: `rake r2p2:build_flash`（必要なら）または既に flash 済みなら skip
- Task ごと: `rake r2p2:upload_mrb SRC=mrbgems/picoruby-stackchan-protocol/examples/ble_smoke.rb && rake r2p2:reset && sleep 10`

---

### Task 1: Switch Gemfile to local rb-corebluetooth-mac

**Files:**
- Modify: `pc/stackchan-protocol/Gemfile`
- Modify (auto): `pc/stackchan-protocol/Gemfile.lock`

- [ ] **Step 1: Edit Gemfile**

`pc/stackchan-protocol/Gemfile` を以下に書き換え (現状は `gemspec` のみ):

```ruby
source "https://rubygems.org"

gemspec

# Local path during BLE bring-up. Switch to git: source after rb-corebluetooth-mac
# stabilizes (see docs/superpowers/specs/2026-05-16-...design.md "Out of scope").
gem 'rb-corebluetooth-mac', path: '/Users/bash/dev/src/github.com/bash0C7/rb-corebluetooth-mac'
```

- [ ] **Step 2: Run bundle install**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/pc/stackchan-protocol
bundle install
```

期待: 「Bundle complete!」が末尾に出る。Swift native ext build が ~30s 走る。失敗したら swift toolchain (swiftly) を確認する。

- [ ] **Step 3: Verify gem is wired**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/pc/stackchan-protocol
bundle list | grep rb-corebluetooth-mac
```

期待出力 (path source 表示):

```
  * rb-corebluetooth-mac (0.2.1 ...)
```

末尾に `at /Users/bash/dev/src/github.com/bash0C7/rb-corebluetooth-mac` 系の path source 注釈が付いていれば OK。

- [ ] **Step 4: Smoke load test**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/pc/stackchan-protocol
bundle exec ruby -r corebluetooth_mac -e 'puts CoreBluetoothMac::VERSION'
```

期待出力: gem version (例 `0.2.1`)。エラーが出たら Gemfile / bundle install の前段に戻る。

- [ ] **Step 5: Commit**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby
git add pc/stackchan-protocol/Gemfile pc/stackchan-protocol/Gemfile.lock
git commit -m "$(cat <<'EOF'
feat(ble): wire rb-corebluetooth-mac path local in pc/stackchan-protocol

Phase 2 autonomous BLE verification loop needs Mac-side CoreBluetooth
central. Path-local during bring-up; switch to git: source once gem stabilizes.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Implement exe/stackchan-ble-verify skeleton + state_check phase

**Files:**
- Create: `pc/stackchan-protocol/exe/stackchan-ble-verify`

このタスクでは device 不要 (state_check phase は permission/adapter チェックのみで、CoreBluetooth daemon との通信成立すれば pass)。

- [ ] **Step 1: Create the CLI file**

`pc/stackchan-protocol/exe/stackchan-ble-verify` を新規作成、以下を書き込む:

```ruby
#!/usr/bin/env ruby
# frozen_string_literal: true

# stackchan-ble-verify — autonomous BLE verification loop against a CoreS3
# running ble_smoke.rb. See docs/superpowers/specs/2026-05-16-ble-mac-
# autonomous-verification-loop-design.md for the phase contract and exit codes.

require 'bundler/setup'
require 'corebluetooth_mac'

DEVICE_NAME    = ENV.fetch('BLE_DEVICE_NAME',  'StackChan-PicoRuby')
SCAN_TIMEOUT   = Float(ENV.fetch('BLE_SCAN_TIMEOUT', '10'))
NOTIFY_WAIT    = Float(ENV.fetch('BLE_NOTIFY_WAIT',  '6'))
STATE_TIMEOUT  = Float(ENV.fetch('BLE_STATE_TIMEOUT', '5'))

NUS_SERVICE = '6e400001-b5a3-f393-e0a9-e50e24dcca9e'
NUS_RX_CHAR = '6e400002-b5a3-f393-e0a9-e50e24dcca9e'
NUS_TX_CHAR = '6e400003-b5a3-f393-e0a9-e50e24dcca9e'
GAP_SERVICE = '1800'
GAP_NAME_CHAR = '2a00'
DIAG_SERVICE = 'ffe0'
DIAG_CHAR    = 'ffe1'

EXPECTED_GAP_NAME = 'StackChan-PicoRuby'
EXPECTED_DIAG     = 'PicoRubyTest'

def phase(name)
  puts "[verify] #{name}"
end

def fail_exit(code, phase_name, reason, domain: 'n/a')
  warn "[FAIL] phase=#{phase_name} reason=#{reason} domain=#{domain}"
  exit code
end

def run
  central = nil
  begin
    phase 'state_check'
    central = CoreBluetoothMac::Central.new(state_timeout: STATE_TIMEOUT)
    puts "[verify] state_check OK (central_id=#{central.central_id})"

    # NOTE: subsequent phases (scan / connect / discover / read / write /
    # subscribe / teardown) added in later tasks.

    puts '[verify] PARTIAL (state_check only — later phases not yet implemented)'
  rescue CoreBluetoothMac::Error => e
    case e.domain
    when :closed, :cb
      fail_exit 2, 'state_check', "adapter not usable: #{e.message}", domain: e.domain
    else
      raise
    end
  ensure
    central&.close
  end
end

run
```

- [ ] **Step 2: Mark executable**

```bash
chmod +x /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/pc/stackchan-protocol/exe/stackchan-ble-verify
```

- [ ] **Step 3: Run skeleton**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/pc/stackchan-protocol
bundle exec exe/stackchan-ble-verify
echo "exit=$?"
```

期待出力 (順序保持):

```
[verify] state_check
[verify] state_check OK (central_id=...)
[verify] PARTIAL (state_check only — later phases not yet implemented)
exit=0
```

失敗ケース:
- permission 拒否 / Bluetooth off → `[FAIL] phase=state_check reason=adapter not usable: ... domain=closed` + exit 2 → System Settings > Privacy & Security > Bluetooth で terminal app を許可してから再実行

- [ ] **Step 4: Commit**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby
git add pc/stackchan-protocol/exe/stackchan-ble-verify
git commit -m "$(cat <<'EOF'
feat(ble): exe/stackchan-ble-verify skeleton with state_check phase

CLI structure + fail_exit helper + exit code conventions. Subsequent
phases (scan/connect/discover/read/write/subscribe) added incrementally.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Add scan + connect phases

**Files:**
- Modify: `pc/stackchan-protocol/exe/stackchan-ble-verify`

このタスクから device が advertise 状態である必要がある。

- [ ] **Step 1: Ensure device is advertising**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby
rake r2p2:upload_mrb SRC=mrbgems/picoruby-stackchan-protocol/examples/ble_smoke.rb
rake r2p2:reset
sleep 10
```

期待: upload_mrb で `[upload_mrb] compiled ... bytes` + `DONE_ACK ok` 出る、reset で `reset sent`。10s sleep の間に sleep_ms 2000 + BLE init + advertise 開始。

- [ ] **Step 2: Replace the run method's body to add scan + connect**

`exe/stackchan-ble-verify` の `run` メソッド全体を以下に置き換える:

```ruby
def run
  central = nil
  peripheral = nil
  begin
    phase 'state_check'
    central = CoreBluetoothMac::Central.new(state_timeout: STATE_TIMEOUT)
    puts "[verify] state_check OK (central_id=#{central.central_id})"

    phase 'scan'
    devices = central.scan(name: DEVICE_NAME, timeout: SCAN_TIMEOUT)
    if devices.empty?
      fail_exit 5, 'scan', "no device named #{DEVICE_NAME.inspect} found within #{SCAN_TIMEOUT}s"
    end
    device = devices.first
    puts "[verify] scan OK (#{devices.size} device, identifier=#{device.identifier} rssi=#{device.rssi} name=#{device.name.inspect})"
    if device.name != EXPECTED_DEVICE_NAME
      fail_exit 5, 'scan', "device name mismatch: got #{device.name.inspect} expected #{EXPECTED_DEVICE_NAME.inspect}"
    end

    phase 'connect'
    peripheral = central.connect(device, timeout: 5.0)
    puts "[verify] connect OK"

    # NOTE: discover / read / write / subscribe added in later tasks.

    puts '[verify] PARTIAL (through connect — later phases not yet implemented)'
  rescue CoreBluetoothMac::Error => e
    case e.domain
    when :closed, :cb
      fail_exit 2, 'unknown', "adapter not usable: #{e.message}", domain: e.domain
    when :timeout
      fail_exit 3, 'unknown', "timeout: #{e.message}", domain: e.domain
    when :connection
      fail_exit 4, 'unknown', "connection lost: #{e.message}", domain: e.domain
    else
      raise
    end
  ensure
    central&.disconnect(peripheral) if peripheral
    central&.close
  end
end
```

- [ ] **Step 3: Run end-to-end**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/pc/stackchan-protocol
bundle exec exe/stackchan-ble-verify
echo "exit=$?"
```

期待出力:

```
[verify] state_check
[verify] state_check OK (central_id=...)
[verify] scan
[verify] scan OK (1 device, identifier=... rssi=-XX name="StackChan-PicoRuby")
[verify] connect
[verify] connect OK
[verify] PARTIAL (through connect — later phases not yet implemented)
exit=0
```

失敗ケース:
- scan で no device → device side advertise 期限切れ (60s 過ぎ) の可能性。Step 1 やり直し
- name mismatch → 別の StackChan が advertise 中。`BLE_DEVICE_NAME` env で別名指定可
- connect timeout → device がぶら下がってる可能性、`rake r2p2:reset` で再起動

- [ ] **Step 4: Commit**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby
git add pc/stackchan-protocol/exe/stackchan-ble-verify
git commit -m "$(cat <<'EOF'
feat(ble): add scan + connect phases to stackchan-ble-verify

Bring-up against ble_smoke.rb advertising as StackChan-PicoRuby. Tested
through connect; subsequent GATT phases pending.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Add discover_services + assert_services phase

**Files:**
- Modify: `pc/stackchan-protocol/exe/stackchan-ble-verify`

- [ ] **Step 1: Ensure device is advertising**

scan 60s window 切れてるなら以下:

```bash
cd /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby
rake r2p2:upload_mrb SRC=mrbgems/picoruby-stackchan-protocol/examples/ble_smoke.rb
rake r2p2:reset
sleep 10
```

- [ ] **Step 2: Insert discover + assert_services between connect and PARTIAL**

`exe/stackchan-ble-verify` の `connect` phase の直後 (`puts "[verify] connect OK"` の次の行) と `puts '[verify] PARTIAL ...'` の間に以下を挿入:

```ruby
    phase 'discover'
    peripheral.discover_services(timeout: 5.0)
    peripheral.services.each do |svc|
      svc.discover_characteristics(timeout: 5.0)
    end
    puts "[verify] discover OK (#{peripheral.services.size} services)"

    phase 'assert_services'
    missing = []
    missing << DIAG_SERVICE unless peripheral.find_service(DIAG_SERVICE)
    missing << NUS_SERVICE  unless peripheral.find_service(NUS_SERVICE)
    unless missing.empty?
      warn ''
      warn 'Mac CoreBluetooth GATT cache may be stale.'
      warn 'Recovery options:'
      warn '  1. sudo pkill bluetoothd  (Bluetooth daemon restart, services re-fetched on next connect)'
      warn '  2. System Settings > Bluetooth > 該当 device を Forget (UI 操作必要)'
      warn '  3. CoreS3 BD addr 変更で peripheral identifier ごと変える (要 ble_smoke.rb 改修)'
      warn ''
      fail_exit 5, 'assert_services', "missing services: #{missing.inspect}"
    end
    puts '[verify] assert_services OK (FFE0 / NUS present)'
```

**Apple platform note (2026-05-16 finding):** GAP (0x1800) と GATT (0x1801) は `discoverServices(nil)` の返り値から CoreBluetooth が filter する。device 名は scan response の `device.name` から取るので、Task 3 の scan phase で assert する (この plan Task 3 の Step 2 の挿入時にすでに `EXPECTED_DEVICE_NAME` チェックが入った形にしてある)。

`PARTIAL` メッセージは "through assert_services — later phases not yet implemented" に更新。

- [ ] **Step 3: Run end-to-end**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/pc/stackchan-protocol
bundle exec exe/stackchan-ble-verify
echo "exit=$?"
```

期待出力末尾:

```
[verify] discover
[verify] discover OK (2 services)
[verify] assert_services
[verify] assert_services OK (FFE0 / NUS present)
[verify] PARTIAL (through assert_services — later phases not yet implemented)
exit=0
```

失敗ケース (cache trap):
- `[FAIL] phase=assert_services reason=missing services: ["6e400001-..."]` → stderr に recovery 手順出る
- Recovery: `sudo pkill bluetoothd` 試す → 再実行 (user 操作)
- それでもダメ → user に escalation (BD addr 変更検討)

- [ ] **Step 4: Commit**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby
git add pc/stackchan-protocol/exe/stackchan-ble-verify
git commit -m "$(cat <<'EOF'
feat(ble): add discover + assert_services phases with cache trap recovery hint

FFE0 / NUS service presence check (Apple filters GAP 0x1800). Mac
CoreBluetooth GATT cache stale-state diagnostic prints recovery options
to stderr.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Add read_ffe1 phase (read_gap_name dropped per Apple filter finding)

**Files:**
- Modify: `pc/stackchan-protocol/exe/stackchan-ble-verify`

**Why no read_gap_name:** Apple CoreBluetooth filters GAP (0x1800) so `peripheral.find_characteristic('2a00')` returns nil. Device name assertion moved to `scan` phase (Task 3) using `device.name` from the advertisement local-name field.

- [ ] **Step 1: Ensure device is advertising**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby
rake r2p2:upload_mrb SRC=mrbgems/picoruby-stackchan-protocol/examples/ble_smoke.rb
rake r2p2:reset
sleep 10
```

- [ ] **Step 2: Insert read_ffe1 phase between assert_services and PARTIAL**

`assert_services OK` を出した行のあとに以下を挿入:

```ruby
    phase 'read_ffe1'
    diag_ch = peripheral.find_characteristic(DIAG_CHAR)
    if diag_ch.nil?
      fail_exit 5, 'read_ffe1', "FFE1 characteristic not found"
    end
    diag_val = diag_ch.read(timeout: 5.0).force_encoding('UTF-8')
    unless diag_val == EXPECTED_DIAG
      fail_exit 5, 'read_ffe1', "FFE1 value mismatch: got #{diag_val.inspect} expected #{EXPECTED_DIAG.inspect}"
    end
    puts "[verify] read_ffe1 OK (#{diag_val.inspect})"
```

`PARTIAL` メッセージは "through read_ffe1 — NUS RX/TX phases pending" に更新。

- [ ] **Step 3: Run end-to-end**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/pc/stackchan-protocol
bundle exec exe/stackchan-ble-verify
echo "exit=$?"
```

期待出力末尾:

```
[verify] read_ffe1
[verify] read_ffe1 OK ("PicoRubyTest")
[verify] PARTIAL (through read_ffe1 — NUS RX/TX phases pending)
exit=0
```

- [ ] **Step 4: Commit**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby
git add pc/stackchan-protocol/exe/stackchan-ble-verify
git commit -m "$(cat <<'EOF'
feat(ble): add read_ffe1 phase to stackchan-ble-verify

Phase 1 regression check: FFE1 read == "PicoRubyTest". read_gap_name
dropped because Apple CoreBluetooth filters 0x1800 from discoverServices.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Add NUS RX write + NUS TX subscribe + teardown + PASS

**Files:**
- Modify: `pc/stackchan-protocol/exe/stackchan-ble-verify`

- [ ] **Step 1: Ensure device is advertising**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby
rake r2p2:upload_mrb SRC=mrbgems/picoruby-stackchan-protocol/examples/ble_smoke.rb
rake r2p2:reset
sleep 10
```

- [ ] **Step 2: Replace PARTIAL block with NUS exercise + PASS**

`read_ffe1 OK` 行のあとから、`PARTIAL` を出してた行までを以下に置き換える:

```ruby
    phase 'nus_write'
    rx_ch = peripheral.find_characteristic(NUS_RX_CHAR)
    if rx_ch.nil?
      fail_exit 5, 'nus_write', "NUS RX characteristic #{NUS_RX_CHAR} not found"
    end
    seq = Time.now.to_i
    rx_ch.write_without_response("ping #{seq}\n")
    puts "[verify] nus_write OK (sent ping #{seq})"

    phase 'nus_subscribe'
    tx_ch = peripheral.find_characteristic(NUS_TX_CHAR)
    if tx_ch.nil?
      fail_exit 5, 'nus_subscribe', "NUS TX characteristic #{NUS_TX_CHAR} not found"
    end
    sub = tx_ch.subscribe
    received = []
    deadline = Time.now + NOTIFY_WAIT
    while (remaining = deadline - Time.now) > 0
      v = sub.next_value(timeout: remaining)
      break if v == false  # subscription closed/drained terminal
      next  if v.nil?      # timeout, deadline check on next iteration
      received << v
    end
    tx_ch.unsubscribe
    matching = received.select { |frame| frame.force_encoding('UTF-8') =~ /\Aping #\d+\n\z/ }
    if matching.empty?
      fail_exit 5, 'nus_subscribe',
        "no matching notify in #{NOTIFY_WAIT}s (got #{received.size} frames: #{received.map(&:inspect).join(', ')})"
    end
    puts "[verify] nus_subscribe OK (got #{received.size} notify, matching=#{matching.size}, first=#{matching.first.inspect})"

    phase 'teardown'
    central.disconnect(peripheral)
    peripheral = nil  # so ensure block doesn't double-disconnect
    central.close
    central = nil
    puts '[verify] teardown OK'

    puts '[verify] PASS'
```

- [ ] **Step 3: Run end-to-end**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/pc/stackchan-protocol
bundle exec exe/stackchan-ble-verify
echo "exit=$?"
```

期待出力末尾:

```
[verify] nus_write
[verify] nus_write OK (sent ping 1747...)
[verify] nus_subscribe
[verify] nus_subscribe OK (got 1 notify, matching=1, first="ping #1\n")
[verify] teardown
[verify] teardown OK
[verify] PASS
exit=0
```

`got 0 notify` の場合: device 側 CCCD subscribe 検知が動いてない可能性。`ble_smoke.rb` の `heartbeat_callback` で `@notify_enabled = true` が立ってるか、device 側 serial log でも確認 (別 task)。

- [ ] **Step 4: Commit**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby
git add pc/stackchan-protocol/exe/stackchan-ble-verify
git commit -m "$(cat <<'EOF'
feat(ble): complete stackchan-ble-verify with NUS write/subscribe + teardown

Phase 2 NUS exercise: write_without_response RX, subscribe TX, drain
notifications for NOTIFY_WAIT seconds, assert >=1 frame matching
/^ping #\\d+\\n$/. Final teardown + PASS marker for exit 0.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: Add rake r2p2:ble_verify task

**Files:**
- Modify: `Rakefile`

- [ ] **Step 1: Insert task at end of `namespace :r2p2 do` block**

`Rakefile` の `namespace :r2p2 do` ブロック内の最後 (`task :verify_led do ... end` の後) に以下を追加 (`end` の直前):

```ruby
  # Mac autonomous BLE verification loop. Composes upload_mrb (host picorbc +
  # picomodem) + reset (RTS pulse) + sleep (autostart + sleep_ms 2000 + BLE
  # init) + stackchan-ble-verify (Mac CoreBluetooth central scan/connect/
  # discover/read/write/subscribe). Single command for Claude Code to assert
  # the full device→Mac BLE path with exit 0 / non-zero.
  desc 'autonomous BLE verify loop: upload ble_smoke.rb (.mrb) + reset + Mac-side verify'
  task :ble_verify do
    ENV['SRC'] = 'mrbgems/picoruby-stackchan-protocol/examples/ble_smoke.rb'
    Rake::Task['r2p2:upload_mrb'].invoke
    Rake::Task['r2p2:reset'].invoke
    autostart_wait = ENV.fetch('AUTOSTART_WAIT', '10').to_i
    puts "[ble_verify] waiting #{autostart_wait}s for autostart (sleep_ms 2000 + BLE init + advertise)..."
    sleep autostart_wait
    Dir.chdir(File.expand_path('pc/stackchan-protocol', __dir__)) do
      sh 'bundle', 'exec', 'exe/stackchan-ble-verify'
    end
  end
```

- [ ] **Step 2: Smoke-list the new task**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby
rake -T r2p2:ble_verify
```

期待出力:

```
rake r2p2:ble_verify  # autonomous BLE verify loop: upload ble_smoke.rb (.mrb) + reset + Mac-side verify
```

- [ ] **Step 3: Commit**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby
git add Rakefile
git commit -m "$(cat <<'EOF'
feat(rake): add r2p2:ble_verify autonomous loop task

Composes upload_mrb + reset + sleep + stackchan-ble-verify so Claude
Code can assert the full device→Mac BLE path in one rake invocation.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: End-to-end loop verification on hardware

**Files:** None modified by Claude in this task. CLI + Rakefile already committed.

- [ ] **Step 1: Make sure CoreS3 is reachable**

```bash
ls /dev/cu.usbmodem*
```

期待: 1 つ以上の `/dev/cu.usbmodem*` がリストされる。0 個 → USB 挿し直し / 別端子試す (人間操作)。

- [ ] **Step 2: Run the full loop**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby
rake r2p2:ble_verify 2>&1 | tee tmp/longrun/ble_verify_e2e.log
echo "exit=$?"
```

期待 (success path):

```
[upload_mrb] compiled ... bytes
... DONE_ACK ok ...
reset sent
[ble_verify] waiting 10s for autostart ...
[verify] state_check
[verify] state_check OK (central_id=...)
[verify] scan
[verify] scan OK (1 device, identifier=... rssi=-XX)
[verify] connect
[verify] connect OK
[verify] discover
[verify] discover OK (3 services)
[verify] assert_services
[verify] assert_services OK (GAP / FFE0 / NUS present)
[verify] read_gap_name
[verify] read_gap_name OK ("StackChan-PicoRuby")
[verify] read_ffe1
[verify] read_ffe1 OK ("PicoRubyTest")
[verify] nus_write
[verify] nus_write OK (sent ping ...)
[verify] nus_subscribe
[verify] nus_subscribe OK (got N notify, matching=M, first="ping #1\n")
[verify] teardown
[verify] teardown OK
[verify] PASS
exit=0
```

- [ ] **Step 3: Branch on outcome**

**PASS の場合:**
- log を `tmp/longrun/ble_verify_e2e.log` に残してこの task 完了。次の step (commit) に進む。

**FAIL の場合 (cache trap 例: missing services):**
- stderr の recovery 手順を user に提示
- `sudo pkill bluetoothd` を user に依頼 (sudo 要なので claude 直叩き不可)
- 再実行 `rake r2p2:ble_verify`
- それでも FAIL → user escalation (BD addr 変更 / GATT Service Changed 実装は別 spec)

**FAIL の場合 (nus_subscribe で got 0 notify):**
- device 側 ble_smoke.rb の `heartbeat_callback` で `@notify_enabled = (cccd == "\\x01\\x00")` が走ってない or `request_can_send_now_event` が dispatch されてない可能性
- 別 capture: `bin/capture-with-pty 30 tmp/longrun/ble_nus_diag.log rake r2p2:monitor` で serial log を取って、Mac 側再実行と並べる
- 結論次第で picoruby-ble C 拡張 or ble_smoke.rb の bug fix を別 task で起こす

- [ ] **Step 4: Record artifact + close task**

`tmp/longrun/ble_verify_e2e.log` は `.gitignore` 配下なら commit 不要。PASS の場合は task list の #14 を completed に更新するだけ。FAIL の場合は memory に 1 行 finding 残す (cache trap 発生条件 / recovery が効いた手順 / どこで break が起きたか)。

```bash
# PASS 時:
# (commit 不要、log は gitignore 下)

# FAIL 時:
# memory 1 行追加 (~/.claude/projects/.../memory/ 配下)、別タスクで詰める
```

---

## Self-Review (post-write)

Spec coverage check:

| Spec section / requirement | Task |
|---|---|
| Goal: 1 cmd exit 0/non-zero | Task 7 + 8 |
| state_check phase | Task 2 |
| scan phase | Task 3 |
| connect phase | Task 3 |
| discover phase | Task 4 |
| assert_services (GAP/FFE0/NUS) | Task 4 |
| read GAP Device Name == "StackChan-PicoRuby" | Task 3 (scan-time `device.name` assert; Apple filters GAP from GATT) |
| read FFE1 == "PicoRubyTest" | Task 5 |
| NUS RX write_without_response | Task 6 |
| NUS TX subscribe + 6s notify drain + assert ≥1 ping pattern | Task 6 |
| teardown (disconnect + close) | Task 6 |
| PASS marker + exit 0 | Task 6 |
| Exit codes 2/3/4/5/9 | Task 2 (helper) + Task 3 (rescue 拡張) |
| silent rescue 禁止 (domain switch) | Task 3 rescue block |
| Cache trap recovery message | Task 4 |
| Gemfile path local | Task 1 |
| rake r2p2:ble_verify task | Task 7 |
| End-to-end run on real hardware | Task 8 |
| Out of scope items (Service Changed / BD addr / WebSocket) | 意図的に未実装、Task 8 escalation で fall-through |

No placeholders。各 step に exact code + exact command + expected output あり。method 名 (`subscribe` / `next_value` / `find_characteristic` / `find_service`) は rb-corebluetooth-mac lib/*.rb で確認済み (Task 0 相当の探索フェーズで完了)。

Type consistency:
- `peripheral` 変数は Task 3 で `central.connect` の戻り → Task 4-6 で同一
- `central.disconnect(peripheral)` Task 3 ensure block + Task 6 teardown 両方で使用、型一致
- `Subscription#next_value` の戻り値 (String / nil / false) の handling は Task 6 で全分岐カバー

---

## Execution Notes

- 全 task 完了後、`rake r2p2:ble_verify` が exit 0 を返すのを 1 回連続で確認する (flaky 防止)
- cache trap が出た場合の memory 追記は task 8 内で完結させる (別 follow-up にしない)
- `rb-corebluetooth-mac` の path → git: 切り替えは spec の out of scope。本 plan の goal 達成後、user に提示してから別 task で実施
