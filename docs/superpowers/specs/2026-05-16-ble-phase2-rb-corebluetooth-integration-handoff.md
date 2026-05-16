# 2026-05-16 BLE Phase 2 — rb-corebluetooth-mac 統合 引き継ぎ

## 経緯

2026-05-15〜16 で stackchan-picoruby Phase 1 BLE peripheral bring-up が **iPhone nRF Connect 経由で空中検証完了** した (advertise → connect → service discovery → 0xFFE1 characteristic read = "PicoRubyTest")。3 repo (picoruby fork / R2P2-ESP32 / stackchan-picoruby) で連動 local commit 済、push は user 手動。

Phase 2 では Mac 側を CoreBluetooth ネイティブで叩く **rb-corebluetooth-mac** gem (別 repo、別 Claude Code session で開発中) と統合し、CoreS3 ↔ Mac の BLE serial-like 双方向通信路を完成させる。Phase 2 開始のトリガーは **user から「gem できた」通知**。

## Phase 1 で確定した状態 (Phase 2 開始時の前提)

### 3 repo の commit (全て branch `feature/ble-bringup`、push 保留中)

- **bash0C7/picoruby** (`R2P2-ESP32/components/picoruby-esp32/picoruby/` 配下、vendored submodule)
  - HEAD: `d4909f2a` feat(picoruby-ble): make build host-aware so ESP32 and host can opt out of CYW43
  - その下: `658f65d0` feat(picoruby-ble/esp32): add ESP32 port (btstack_owner 等)、`4b412800` fix(picoruby-ble/esp32): own profile_data in BLE_init + SM/RPA hardening + att_db debug
- **bash0C7/R2P2-ESP32**
  - HEAD: `0b559e9` build(picoruby-esp32): integrate bash0C7/picoruby fork w/ picoruby-ble ESP32 port
  - その下: `e9289de` fix(sdkconfigs/bt_btstack): trim COEX disable to CONFIG_SW_COEXIST_ENABLE=n only
- **bash0C7/stackchan-picoruby**
  - HEAD: `4a7a41a` feat(ble): CoreS3 Phase 1 BLE peripheral bring-up smoke + tooling

Phase 2 開始時に **3 repo とも `git log -3 --oneline` で SHA 同一性を確認** すること。drift してたら user に確認。

### device-side コードの現状

`mrbgems/picoruby-stackchan-protocol/examples/ble_smoke.rb` は次の通り:
- 60 秒 advertise window で exit (upload race-free)
- GAP service (0x1800) + Device Name characteristic "StackChan-PicoRuby"
- **diagnostic 0xFFE0 service + 0xFFE1 char (static value "PicoRubyTest")** ← Phase 1 検証で使った demo、Phase 2 で NUS に置き換え or 共存
- profile_data の Ruby bytes hex dump + `@db` ivar 保持 (debug 用、残しておく)

`ports/esp32/ble.c` (bash0C7/picoruby submodule 内) は:
- `att_db` の C-side owned copy (malloc+memcpy in `BLE_init`) — Ruby String GC 独立に att_server_init pointer 永続化
- SM hardening: `sm_set_authentication_requirements(0)` / `gap_random_address_set_mode(GAP_RANDOM_ADDRESS_TYPE_OFF)` (BTstack 内部の auth/RPA 経路を簡素化)
- ESP_LOGI debug for att_db ptr/first/last4/len + att_server_init returned
- BTstack thread に dispatch する pattern (`picoruby_btstack_ensure_started` / `picoruby_btstack_run_sync`)

### 既知の品質課題 (Phase 2 では blocker じゃない、後追い)

1. **air interface に random NRPA `11:98:43:93:92:E9` が出る** (device-side log は public `44:1B:F6:E2:05:66`)。`gap_random_address_set_mode(OFF)` 内部状態は `le_own_addr_type = PUBLIC` で正しいのに controller 経路で random が emit される、安定 NRPA。BTstack source 調査済 (`hci.c:9060-9072` の `LE_ADVERTISEMENT_TASKS_SET_ADDRESS_SET_0` 経路 + sm.c の `hci_le_random_address_set` 呼び出し chain) だが直接の trigger が未特定。**機能上は問題なし**、scan で見えるし connect+GATT も動く。Phase 2 で rb-corebluetooth-mac から見た時の挙動を観察、必要なら別タスク化
2. **macOS CoreBluetooth GATT 構造を address ごとに永続キャッシュ** する罠あり (memory: feedback_mac_corebluetooth_gatt_cache_trap.md)。同じ peripheral address で過去 "0 services" を見せたら以後その値を返す。bluetoothd 再起動でも消えない事例。Phase 2 の Mac 側統合では:
   - 初期検証は **iPhone nRF Connect 併用** ([[verify-at-air-interface]] 規律)
   - rb-corebluetooth-mac 側で cache invalidate API がある場合はそれを使う、または「device の Public address を変える」(esp_base_mac_addr_set) 等で逃げる

## Phase 2 のスコープ

### 主目的

stackchan-picoruby (CoreS3) と Mac (rb-corebluetooth-mac) の間で **BLE serial-like の双方向 byte 通信路** を確立し、`stackchan-control` (Mac CLI) や PC 側 AI からコマンド送受信が WiFi 経由でなく BLE 経由でできる状態にする。

### Step 1: device 側 NUS service 追加 (Task #6)

`ble_smoke.rb` (or 別 example) に **Nordic UART Service (NUS)** を追加:
- Service UUID: `6e400001-b5a3-f393-e0a9-e50e24dcca9e` (128-bit)
- RX characteristic: `6e400002-b5a3-f393-e0a9-e50e24dcca9e` — **Write Without Response** (central → peripheral、CLI command を受信)
- TX characteristic: `6e400003-b5a3-f393-e0a9-e50e24dcca9e` — **Notify** (peripheral → central、log や ack を送信)

picoruby-ble の `GattDatabase` API で 128-bit UUID は 16-byte String で渡せる (`uuid2str` が `length == 16` を支持)。`add_characteristic` の properties に NOTIFY を立てると CCCD descriptor も自動追加される (`flag_by_uuid` の NOTIFY/INDICATE 分岐)。

dynamic value (write 受信 / read 提供) は `BLE_write_data` / `BLE_read_data` callback 経由。`BLE` Ruby class でそれぞれ override する。

検証は iPhone nRF Connect でまず:
- RX に「Hello」を Write Without Response → device の serial log に届くか
- TX に Subscribe → device 側から push したデータが iPhone に Notify 届くか

NUS が iPhone で動いてから Mac 側統合へ。

### Step 2: rb-corebluetooth-mac 統合

別 repo `bash0C7/rb-corebluetooth-mac` で開発中の gem を `stackchan-picoruby` の `Gemfile` に **path 依存** で追加。`pc/stackchan-protocol/Gemfile` (uart gem を持ってるところ) を拡張するのが自然。

Ruby central 実装目安:
```ruby
require 'corebluetooth'

central = CoreBluetooth::Central.new
periph = central.scan_and_connect(name: 'StackChan-PicoRuby', timeout: 10)
nus = periph.service('6e400001-b5a3-f393-e0a9-e50e24dcca9e')
rx = nus.characteristic('6e400002-b5a3-f393-e0a9-e50e24dcca9e')
tx = nus.characteristic('6e400003-b5a3-f393-e0a9-e50e24dcca9e')

tx.on_notify { |bytes| puts "from device: #{bytes}" }
rx.write_without_response("hello\n")
```

API の正確な形は rb-corebluetooth-mac の `README.md` / `examples/` を見て決める。`rb-foundation-model-mac` の Swift package 流儀踏襲なので Mkmf.create_swift_makefile + `@_cdecl` で C ABI export + Ruby C 拡張 dlopen のパターン。

### Step 3: 統合 demo / CLI

`pc/stackchan-protocol/exe/` 配下に新 CLI、例えば `stackchan-ble-control` を作る。stackchan-control (uart) と同 op (led / face / etc) を BLE 経由で投げる。device 側の `mrbgems/picoruby-stackchan-protocol/mrblib/` の Protocol dispatcher が **NUS RX で受信したコマンドを既存 frame parser に流す** ようにする (USB-serial と並列対応)。

注意:
- BTstack の att_write_callback は **btstack thread** で呼ばれる。Ruby thread からの読み取りには Queue で挟む (既存 picoruby-ble 設計)
- Mac 側 cache 問題: rb-corebluetooth-mac の cache invalidate API を活用、または iPhone 並行検証

## Phase 2 で使う既存 memory / reference

- `feedback-verify-at-air-interface` — device-side log だけで OK 判定せず外部 receiver (iPhone) で必ず air-interface 検証
- `feedback-mac-corebluetooth-gatt-cache-trap` — Mac は services キャッシュ激重、iPhone 併用
- `ble-phase1-complete` — Phase 1 の commit SHA / 検証手順 / 未解決品質課題
- `mac-communication-path` — Web Bluetooth bridge は撤回、CoreBluetooth gem (rb-corebluetooth-mac) が主 path
- `local-commit-autonomy-bash0c7-only` — `/Users/bash/dev/src/github.com/bash0C7/<repo>/` 直下なら commit 自由、submodule 等の nested は `git remote` 確認継続
- `btstack-offspec-picoruby-ble` — BTstack は ESP-IDF 公式 host stack 外、bug は picoruby-ble fork 側で fix

## Phase 2 開始前にやること

1. `git status` を 3 repo で確認、Phase 1 commit セットが残ってるか (SHA は上記参照)
2. user に「rb-corebluetooth-mac gem の API doc / examples 場所」確認 (`/Users/bash/dev/src/github.com/bash0C7/rb-corebluetooth-mac/` 想定だが path 確認)
3. iPhone nRF Connect を user の手元に用意してもらう (HITL 検証用)
4. CoreS3 を USB 接続 + 電源 ON (NUS upload + reset + air-interface 検証で必要)

## やってはいけないこと

- 公式 `/Users/bash/dev/src/github.com/m5stack/StackChan` への書き込み (read-only 参照のみ)
- `rb-foundation-model-mac` への変更 (read-only 参照のみ、流儀パクるだけ)
- `picoruby/picoruby` / `picoruby/R2P2-ESP32` upstream への commit (bash0C7/* fork のみ書く)
- Python 利用 (global CLAUDE.md 禁止)
- rake task の screen `-dmS` longrun 化 (本プロジェクト override で subagent foreground 1 個ずつ)
- 物理操作 (USB 抜き差し / boot button 等) を claude 側で自動 recovery 粘る (人間に振る)
- silent rescue (`rescue nil` / 空 rescue) — 例外は log / re-raise / Result 型返却
