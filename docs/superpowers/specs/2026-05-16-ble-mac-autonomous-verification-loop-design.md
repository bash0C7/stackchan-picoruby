# BLE Mac Autonomous Verification Loop — Design (2026-05-16)

## Purpose

Phase 2 BLE bring-up は iPhone nRF Connect での目視確認に依存していて、Claude Code の自動 dev loop に組み込めなかった。具体的には:

- iPhone GATT cache が古い state を持つと NUS service が「No Service」と表示され、人間が iPhone Bluetooth toggle / nRF Connect kill 等の手動 cache invalidate を要求する
- HITL ステップが入ると 1 サイクル数分かかり、Claude が ble_smoke.rb / picoruby-ble C 拡張を直して即検証する高速イテレーションが組めない

ここで `rb-corebluetooth-mac` gem (`/Users/bash/dev/src/github.com/bash0C7/rb-corebluetooth-mac`) が出来たので、Mac 側で BLE central を Ruby から駆動できるようになった。これを使って **Claude Code が 1 コマンド `rake r2p2:ble_verify` を叩くだけで CoreS3 → BLE peripheral → Mac central → assertion → exit code までを完結する自律検証ループ** を構築する。

## Goal

- `rake r2p2:ble_verify` を 1 回叩く → host で .mrb compile → device に upload → device reset → Mac side で scan/connect/discover/read/write/subscribe → 全部 OK で exit 0、どこかで失敗で non-zero
- Claude が exit code + stderr 構造化 message だけ見て次のアクション (修正 or 続行) を判断できる
- HITL なし、人間は USB 抜挿だけ (cache trap recovery 等の限定例外あり)

## Non-goal

- iPhone でも動くこと (Mac だけで OK、CoreS3 ↔ Mac の主 path を作るのが goal)
- rb-corebluetooth-mac 自体への機能追加 (gem 側は読むだけ、改修は別 issue)
- production GATT 服従 (Service Changed / database hash 等の cache invalidate プロトコル) — 今は迂回方針

## Architecture

```
Claude Code
    │
    ▼
rake r2p2:ble_verify  ──┬─► r2p2:upload_mrb (host picorbc + picomodem upload)
                       ├─► r2p2:reset (RTS pulse → CoreS3 boot)
                       ├─► sleep 10 (2s escape hatch + BLE init + advertise)
                       └─► pc/stackchan-protocol/exe/stackchan-ble-verify
                              │
                              ▼
                       rb-corebluetooth-mac (Ruby + Swift native ext)
                              │
                              ▼
                       CoreBluetooth central
                              │
                              ▼ BLE
                       CoreS3 (BTstack peripheral, ble_smoke.rb)
                              │
                              ▼
                       advertise / GATT server (GAP / FFE0 / NUS)
```

## Components

### 1. `pc/stackchan-protocol/exe/stackchan-ble-verify` (新規 CLI)

- 入口: `bundle exec exe/stackchan-ble-verify` (引数なし、env override 可)
- env:
  - `BLE_DEVICE_NAME` (default `"StackChan-PicoRuby"`)
  - `BLE_SCAN_TIMEOUT` (default `10`)
  - `BLE_NOTIFY_WAIT` (default `6`)
- フロー (各 phase は stdout に header `[verify] <phase>` を出す):
  1. `state_check`: `CoreBluetoothMac::Central.new(state_timeout: 5)` — permission/adapter チェック
  2. `scan`: name filter で 10 秒間 scan → `devices.first` を取得 → **`device.name == "StackChan-PicoRuby"` を assert** (Apple は GAP/0x1800 を `discoverServices(nil)` から filter するので、device 名は scan-response advertising data から取る)
  3. `connect`: `central.connect(device, timeout: 5)`
  4. `discover`: `peripheral.discover_services(timeout: 5)` (全 service 取得、Apple filter で GAP 0x1800 / GATT 0x1801 は返らない)
  5. `assert_services`: FFE0 / NUS (`6e400001-b5a3-f393-e0a9-e50e24dcca9e`) 2 service 揃ってるか
  6. `read_ffe1`: FFE0 配下 FFE1 を読んで `"PicoRubyTest"` と equal を assert
  7. `nus_write`: NUS RX (`6e400002-...`) に `"ping #{Time.now.to_i}\n"` を `response: false` で write
  8. `nus_subscribe`: NUS TX (`6e400003-...`) `subscribe` → Ractor pump で 6 秒待って `notify_count >= 1` && 受信 payload が `/^ping #\d+\n/` を assert
  9. `teardown`: `central.disconnect(peripheral)` → `central.close`
- 成功時 stdout 末尾に `[verify] PASS` + exit 0
- 失敗時 stderr に 1 行 `[FAIL] phase=<phase> reason=<reason> domain=<error_domain or n/a>` を出して exit non-zero
- exit code mapping:
  - 0: PASS
  - 2: permission/adapter not usable (`:closed` / `:cb`)
  - 3: timeout (`:timeout`)
  - 4: connection lost (`:connection`)
  - 5: assertion failed (services missing / value mismatch / no notify)
  - 9: その他 (bug 候補、`:discovery` / `:validation` / unknown)

### 2. `pc/stackchan-protocol/Gemfile` 差し替え

- 現状: `gem 'serialport'` 系のみ
- 追加: `gem 'rb-corebluetooth-mac', path: '/Users/bash/dev/src/github.com/bash0C7/rb-corebluetooth-mac'`
- bundle install で Swift native ext build が走る (gem 側 install hook、初回 ~30s)
- **安定後 GitHub 参照に切り替える** (user 指示)、その時は `gem 'rb-corebluetooth-mac', git: 'https://github.com/bash0C7/rb-corebluetooth-mac', branch: 'main'` 想定

### 3. `Rakefile` に `r2p2:ble_verify` task 追加

```ruby
desc 'autonomous BLE verify loop: upload ble_smoke.rb (.mrb) + reset + run Mac-side verify CLI'
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

## Data flow

```
Claude → rake r2p2:ble_verify
  │
  ├─[Rakefile]→ picorbc (host) → tmp/build/ble_smoke.mrb
  │             picomodem-upload → /home/app.mrb (CoreS3 fatfs)
  │
  ├─[Rakefile]→ RTS pulse (Python esp_python) → CoreS3 boot
  │             autostart: /home/app.mrb load → sleep_ms 2000 →
  │             StackChanSmoke.new → att_server_init →
  │             advertise(@adv_data) for 60_000 ms
  │
  └─[Rakefile]→ sleep 10  (escape hatch + init 込み)
                │
                ▼
                exe/stackchan-ble-verify (Ruby + Bundler)
                  │
                  ├─ Central.new → Swift ext init → permission/adapter check
                  ├─ scan → CBCentralManager#scanForPeripherals(name) → device array
                  ├─ connect → CBCentralManager#connect → peripheral
                  ├─ discover_services → CBPeripheral#discoverServices(nil)
                  │   → CBPeripheral#discoverCharacteristics(nil, for: service) per service
                  ├─ read GAP 0x2a00 → "StackChan-PicoRuby"
                  ├─ read FFE1 → "PicoRubyTest"
                  ├─ write NUS RX 6e400002-... "ping ..." (response: false)
                  ├─ subscribe NUS TX 6e400003-... → CBPeripheral#setNotifyValue
                  │   → Ractor pump 6s → notify ≥1 取れたか
                  ├─ disconnect + close
                  └─ stdout: [verify] PASS / stderr: [FAIL] ...
                  → exit code
                │
                ▼
                Claude reads exit code + stderr → 次の action
```

## Error handling

silent rescue 禁止ルール (`~/dev/src/CLAUDE.md`) を守る。`rescue` は必ず以下のいずれか:

- `domain` で switch して構造化 stderr 出力 + 該当 exit code で `exit` (再投出ではなく、CLI として終了するため)
- 完全予期外なら `raise` 通して backtrace を stderr に出す (exit 9 と等価)

例:

```ruby
begin
  # phase work
rescue CoreBluetoothMac::Error => e
  case e.domain
  when :closed, :cb
    fail_exit 2, phase, "adapter not usable: #{e.message} code=#{e.code_name}"
  when :timeout
    fail_exit 3, phase, "timeout: #{e.message}"
  when :connection
    fail_exit 4, phase, "connection lost: #{e.message} code=#{e.code_name}"
  else
    raise  # 9 と等価、backtrace 出る
  end
end

def fail_exit(code, phase, reason, domain: 'n/a')
  warn "[FAIL] phase=#{phase} reason=#{reason} domain=#{domain}"
  exit code
end
```

assertion 失敗 (services missing 等) は通常の `raise AssertionFailed` ではなく、`fail_exit(5, ...)` で直接 exit する (sub-shell から Claude が拾うため backtrace は不要)。

## Mac CoreBluetooth GATT cache trap への防御

memory [[mac-corebluetooth-gatt-cache-trap]] にある通り、Mac CoreBluetooth は peripheral identifier ベースで services を永続キャッシュする。`ble_smoke.rb` を編集して att_db を変えても、Mac 側は古い service 一覧を返す。

最小防御:

- assert_services phase で `find_service` が nil を返した service があれば `[FAIL] phase=assert_services reason=missing services: [...]` + 復旧手順を stderr に明示出力:
  ```
  Mac CoreBluetooth GATT cache may be stale.
  Recovery options:
    1. sudo pkill bluetoothd  (Bluetooth daemon restart, services re-fetched on next connect)
    2. System Settings > Bluetooth > 該当 device を Forget (UI 操作必要)
    3. CoreS3 BD addr 変更で peripheral identifier ごと変える (要 ble_smoke.rb 改修)
  ```

`tccutil` や `pkill` を CLI 内部からは実行しない (sudo 要求で autonomous loop が止まる)。Claude 側で `sudo pkill bluetoothd` を提案 → user 許可 → ガード解除して実行、というルートにする。

恒久対策 (この spec の scope 外):

- ble_smoke.rb に GATT Service (0x1801) + Service Changed (0x2A05) 追加 → 接続時 indicate
- もしくは ESP32 `esp_base_mac_addr_set` で BD addr を毎 build 変動

## Testing

- 検証スクリプト自体には unit test 書かない。`rb-corebluetooth-mac` 側で test/ がある (テストカバレッジは gem 担当)
- このスクリプトの「動作テスト」は **実機 CoreS3 + Mac で `rake r2p2:ble_verify` を実行して exit 0 が返ること**
- スクリプト single file (~150 行想定) で複雑な分岐少ない → CRuby host test の費用対効果が低い
- 将来 phase 数が増えて分岐複雑化したら mock 化検討

## Build/Run sequence

1. Gemfile 編集 → `bundle install` (Swift ext build に数秒)
2. `exe/stackchan-ble-verify` 実装 + chmod +x
3. `Rakefile` に `r2p2:ble_verify` 追加
4. `rake r2p2:ble_verify` 実機実行
   - 初回: macOS Bluetooth permission prompt 出る → user 許可 → 再実行
   - 2 回目以降: cache trap 出るか観察
5. cache trap 出た場合: 上の Recovery 手順試す → 効いた手順を spec / memory に記録

## Out of scope / followup

- `pc/stackchan-protocol/exe/stackchan-ble-control` のような単発 op CLI (scan / read / write 個別) — Claude loop 完成後、user が REPL 的に叩きたくなったら追加
- GATT Service Changed 実装 — cache trap で詰まったら次の spec
- BD addr randomize — 同上
- WebSocket bridge / Web Bluetooth — `[[mac-communication-path]]` の主 path の別軸、本 spec の scope 外
- CI 化 — Mac BLE は CI に乗らない (Bluetooth permission + 実機要求)、当面 local only
