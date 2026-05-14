# BLE on CoreS3 — Deep Trace & Implementation Spec

> 作成 2026-05-15。3 つの先行実装 (BTstack 公式 ESP32 port / picoruby-ble RP2040 port / StackChan 公式 NimBLE) を line-by-line で読み込んだ結果を、実装に直接使える粒度で集約。

## TL;DR

- **picoruby-ble の RP2040 port は 96% が BTstack pure API**。ESP32 port 化は 20 行 delete + esp-idf init hook 数行追加で完了する見込み (当初見積 50-80 行から大幅縮小)
- **BTstack 公式 ESP32 port が picoruby tree に既に vendored** (`mrbgems/picoruby-r2p2/lib/pico-sdk/lib/btstack/port/esp32/`)。`integrate_btstack.py` でコア部分だけコピー
- **VHCI asynchronous transport** を使う (UART/H4 不要)。`esp_vhci_host_register_callback` で BTstack ↔ Controller bridge
- **ESP-IDF v5.4 で `CONFIG_BT_CONTROLLER_ENABLED=y` 必須**。v5.0 で導入されたフラグ。これがないと main.c L57-61 の `#error` で詰む
- **StackChan 公式は NimBLE + JSON over 4 characteristic**。互換にすると公式 Flutter app がそのまま動く

---

## 1. BTstack 公式 ESP32 port トレース

### 1.1 起動シーケンス (11 step)

main → btstack_init → btstack_main → btstack_run_loop_execute の流れ。app_main task でずっと回る (single-threaded、別 task からの BTstack 呼び出しは `btstack_run_loop_execute_on_main_thread()` 経由のみ)。

| # | 関数 | ファイル | 役割 |
|---|---|---|---|
| 1 | `btstack_init()` | `btstack_port_esp32.c:383` | メイン init。下記 1a-1f を内部呼び出し |
| 1a | `btstack_memory_init()` | btstack.c | Memory pool init |
| 1b | `btstack_run_loop_init(btstack_run_loop_freertos_get_instance())` | `btstack_run_loop_freertos.c:217` | Queue / Semaphore / Event Group / current task handle save |
| 1c | `hci_init(transport_get_instance(), NULL)` | hci.c | HCI layer 初期化 → 内部で `transport_open()` を呼ぶ |
| 1c1 | `esp_bt_controller_mem_release(ESP_BT_MODE_CLASSIC_BT)` | esp-idf | (BLE-only S3 で) Classic 用 RAM 解放 |
| 1c2 | `esp_bt_controller_init(&bt_cfg)` (`BT_CONTROLLER_INIT_CONFIG_DEFAULT()`) | esp-idf | Controller 初期化 |
| 1c3 | `esp_bt_controller_enable(ESP_BT_MODE_BLE)` | esp-idf | Controller enable |
| 1c4 | `esp_vhci_host_register_callback(&vhci_host_cb)` | esp-idf | VHCI callback 登録 (送信完了 / 受信通知) |
| 1d | `btstack_tlv_esp32_get_instance()` | `btstack_port_esp32.c:392` | NVS 初期化 (`nvs_flash_init` + `nvs_open("BTstack", NVS_READWRITE)`) |
| 1e | `le_device_db_tlv_configure()` | btstack | LE bonding DB を NVS にバインド |
| 1f | `hci_add_event_handler()` | hci.c | BTSTACK_EVENT_STATE 監視 |
| 2 | `hci_add_event_handler(&my_handler)` | user | アプリ用イベント handler |
| 3 | `l2cap_init()` | l2cap.c | L2CAP layer |
| 4 | `sm_init()` | sm.c | Security Manager (pairing) |
| 5 | `att_server_init(profile_data, NULL, NULL)` | `att_server.c:73` | GATT database 登録 (`profile_data` は `.gatt` から compile) |
| 6 | `att_server_register_packet_handler(&handler)` | `att_server.c:94` | GATT event handler |
| 7 | `gap_advertisements_set_params(int_min, int_max, type, ...)` | gap.c | Advertisement interval 設定 |
| 8 | `gap_advertisements_set_data(len, data)` | gap.c | Flags + name + UUID payload |
| 9 | `gap_advertisements_enable(1)` | gap.c | Advertise 開始 |
| 10 | `hci_power_control(HCI_POWER_ON)` | hci.c | **Controller power on (実質スタック起動)** |
| 11 | `btstack_run_loop_execute()` | `btstack_run_loop_freertos.c:154` | Blocking loop forever |

### 1.2 VHCI Transport Bridge

ESP32 port は **UART/H4 ではなく VHCI asynchronous mode**。`hci_set_chipset()` 不要。

```
[BTstack hci_send_packet()]
   → transport->send_packet (transport_send_packet, btstack_port_esp32.c:306)
       → esp_vhci_host_send_packet(packet, size)        [Controller受信]

[Controller がパケット完成]
   → host_recv_pkt_cb() (btstack_port_esp32.c:145)
       → ring buffer に書き込み (mutex 保護)
       → btstack_run_loop_execute_on_main_thread() で wake-up
           → transport_deliver_packets() → HCI layer

[Controller 送信完了]
   → host_send_pkt_available_cb() (btstack_port_esp32.c:135)
       → btstack_run_loop_execute_on_main_thread()
           → transport_notify_packet_send() → HCI_EVENT_TRANSPORT_PACKET_SENT
```

### 1.3 必須 sdkconfig (ESP-IDF v5.4 + ESP32-S3 + BLE peripheral)

```
CONFIG_BT_ENABLED=y
CONFIG_BT_CONTROLLER_ENABLED=y                # ★ v5.0+ で必須、これ無いと main.c L57-61 で #error
CONFIG_BT_CONTROLLER_ONLY=y                   # Bluedroid/NimBLE host を使わず BTstack に
CONFIG_BT_BLUEDROID_ENABLED=n
CONFIG_BT_NIMBLE_ENABLED=n
CONFIG_BTDM_CTRL_HCI_MODE_VHCI=y              # VHCI mode (BTstack ESP32 port が前提)
CONFIG_BT_CTRL_HCI_TL_EFF=1
CONFIG_BTDM_CTRL_MODE_BLE_ONLY=y              # ESP32-S3 は BLE only
CONFIG_BT_RESERVE_DRAM=0xdb5c                 # Bluetooth controller 用 DRAM 予約
CONFIG_BTDM_CTRL_BLE_MAX_CONN=9
CONFIG_BTDM_BLE_SCAN_DUPL=y
```

### 1.4 vendored 場所と integrate スクリプト

`/Users/bash/dev/src/github.com/picoruby/picoruby/mrbgems/picoruby-r2p2/lib/pico-sdk/lib/btstack/port/esp32/`:
- `integrate_btstack.py` — `$IDF_PATH/components/btstack/` に core を copy するスクリプト。コピー対象は `src/`, `3rd-party/{bluedroid,hxcmod-player,lc3-google,md5,micro-ecc,yxml}`, `platform/{freertos,lwip}`, `tool/`, `platform/embedded/` (4 ファイルのみ手動 copy)
- `template/main/main.c` — app_main + btstack_init template
- `template/sdkconfig` — sdkconfig defaults
- `components/btstack/CMakeLists.txt` — IDF_VERSION_MAJOR で audio v4/v5 切替済 → BLE only なら audio 全 exclude
- `components/btstack/btstack_port_esp32.c` — VHCI bridge 本体 (transport_init / transport_open / vhci callbacks / btstack_init)
- `components/btstack/btstack_tlv_esp32.c` — NVS namespace `"BTstack"` で bonding 永続化

### 1.5 NVS と LittleFS の衝突

BTstack は NVS namespace `"BTstack"` のみ使用。R2P2 の LittleFS は別 partition なので衝突なし。NVS の他 namespace ("app_config" 等) も独立して使える。

### 1.6 v5.4 への適合作業

| 項目 | v4.4 / v5.0 想定 | v5.4 で必要な対応 |
|---|---|---|
| `CONFIG_BT_CONTROLLER_ENABLED` | (存在しない) | **必須**。menuconfig で enable |
| Audio version check | CMakeLists L47-55 で済 | 自動対応 (IDF_VERSION_MAJOR) |
| `esp_bt_controller_*` API | 同じ | 互換 |
| `esp_vhci_host_*` API | 同じ | 互換 |
| NVS API | 同じ | 互換 |

→ **Build は通るはず。Phase 0 smoke で確証取る**。

---

## 2. picoruby-ble RP2040 port トレース

### 2.1 ports/rp2040/ble.c (250 行) の構造分解と CYW43 依存

| Lines | Section | 依存 | ESP32 アクション |
|---|---|---|---|
| 1-6 | std headers | std | **COPY** |
| 7-9 | `#include "pico/cyw43_arch.h" / "pico/btstack_cyw43.h" / "pico/stdlib.h"` | Pico SDK | **DELETE** (esp-idf 相当を必要なら add) |
| 11-12 | `ble.h` / `ble_common.h` include | port contract | **COPY** (path 同じ) |
| 13-16 | static state (role, callbacks, heartbeat) | BTstack pure | **COPY** |
| 18-31 | `att_read_callback()` | BTstack pure | **COPY** |
| 33-43 | `att_write_callback()` | BTstack pure (con_handle 保存含む) | **COPY** |
| 45-108 | `packet_handler()` (HCI event dispatcher) | BTstack pure | **COPY** |
| 115-125 | `blink_led()` (debug 用、未使用) | CYW43 | **DELETE** |
| 127-136 | `heartbeat_handler()` (1000ms self-reschedule) | BTstack timer pure | **COPY** |
| 138-179 | `BLE_init()` (l2cap_init + sm_init + role 別 init + add_event_handler) | BTstack pure | **COPY** |
| 181-193 | `BLE_hci_power_control()` (HCI_POWER_ON で heartbeat timer start) | BTstack pure | **COPY** |
| 195-199 | `BLE_gap_local_bd_addr()` | BTstack pure | **COPY** |
| 201-249 | GATT Client discovery API 6 関数 | BTstack pure | **COPY** |

**結果**: `ble.c` 250 行のうち、**delete 18 行 (Pico SDK include 7 + blink_led 11) + copy 232 行**。

`ble_peripheral.c` (52 行) と `ble_central.c` (53 行) も同様で各 7 行の Pico SDK include を delete するだけ、機能本体は全 BTstack pure (`gap_advertisements_*` / `att_server_notify` / `gap_set_scan_params` / `gap_connect` / `gap_set_connection_parameters` etc)。

### 2.2 公開 C API contract (port 実装義務)

`include/ble.h` / `ble_peripheral.h` / `ble_central.h` で port が実装する必要のある関数:

**ble.h**:
- `int BLE_init(const uint8_t *profile, int ble_role)`
- `void BLE_hci_power_control(uint8_t power_mode)`
- `void BLE_gap_local_bd_addr(uint8_t *local_addr)`
- `void BLE_push_event(uint8_t *data, uint16_t size)` (これは `src/mruby/ble.c` に既に実装済、port 側は呼ぶだけ)
- `void BLE_heartbeat(void)` (同上)
- `int BLE_write_data(uint16_t att_handle, const uint8_t *data, uint16_t size)` (同上)
- `int BLE_read_data(BLE_read_value_t *read_value)` (同上)
- GATT Central discovery 6 関数

**ble_peripheral.h**:
- `BLE_peripheral_advertise(adv_data, len, connectable)`
- `BLE_peripheral_stop_advertise()`
- `BLE_peripheral_notify(att_handle)`
- `BLE_peripheral_request_can_send_now_event()`

**ble_central.h**:
- `BLE_central_set_scan_params(...)`
- `BLE_central_start_scan()` / `_stop_scan()`
- `BLE_central_gap_connect(addr, addr_type)`

### 2.3 Ruby ↔ C queue モデル

```
mruby state (_mrb)
  ├── packet (uint8_t *) + packet_flag + packet_mutex
  │     ↑ BLE_push_event() で C → queue
  │     ↓ BLE.pop_packet() で Ruby が取得
  ├── write_values: { att_handle => [str, str, ...] }
  │     ↑ att_write_callback → BLE_write_data() で C → queue
  │     ↓ BLE.pop_write_value(att_handle) で Ruby pop (FIFO)
  └── read_values: { att_handle => str }
        ↑ BLE.push_read_value(handle, str) で Ruby が事前 set
        ↓ att_read_callback → BLE_read_data() で C が pull
```

heartbeat は `heatbeat_flag` (bool) のフラグ式。`BLE.pop_heartbeat` が check & reset。

### 2.4 packet handler event 一覧 (役割別)

| role | 受け取る event |
|---|---|
| PERIPHERAL | BTSTACK_EVENT_STATE / HCI_EVENT_DISCONNECTION_COMPLETE / ATT_EVENT_MTU_EXCHANGE_COMPLETE / ATT_EVENT_CAN_SEND_NOW / SM_EVENT_JUST_WORKS_REQUEST (即 `sm_just_works_confirm()`) |
| BROADCASTER | BTSTACK_EVENT_STATE のみ |
| CENTRAL | BTSTACK_EVENT_STATE / HCI_EVENT_LE_META / GAP_EVENT_ADVERTISING_REPORT / GATT_EVENT_* (12 種、discovery / read / write / notify / indication 全部) |
| OBSERVER | BTSTACK_EVENT_STATE / GAP_EVENT_ADVERTISING_REPORT |

### 2.5 mrbgem.rake 拡張 draft

現状:
```ruby
MRuby::Gem::Specification.new('picoruby-ble') do |spec|
  spec.add_dependency 'picoruby-cyw43'
  spec.add_dependency 'picoruby-mbedtls'
end
```

ESP32 対応 (platform 分岐):
```ruby
MRuby::Gem::Specification.new('picoruby-ble') do |spec|
  spec.add_dependency 'picoruby-mbedtls'

  case PICORUBY_PLATFORM   # or build_config 名で判定
  when 'rp2040'
    spec.add_dependency 'picoruby-cyw43'
    spec.cc.files << "#{dir}/ports/rp2040/*.c"
  when 'esp32'
    spec.cc.files << "#{dir}/ports/esp32/*.c"
    # esp-idf BTstack include path は R2P2-ESP32 側 CMakeLists で通す
  end
end
```

---

## 3. StackChan 公式 BLE トレース

### 3.1 host stack
- **NimBLE** (Apache NimBLE)
- `sdkconfig.defaults`: `CONFIG_BT_NIMBLE_ENABLED=y`, `CONFIG_BT_NIMBLE_MEM_ALLOC_MODE_EXTERNAL=y`, `CONFIG_BT_NIMBLE_ATT_PREFERRED_MTU=512`
- ESP32-S3 で WiFi と並行運用

### 3.2 GATT profile (`bleprph.h:42-68`, `gatt_svr.c:81-139`)

**Primary Service** (2 つの UUID で切り替え可):
- 通常: `e2e5e5e0-1234-5678-1234-56789abcdef0`
- App config 用 ALT: `e2e5e5ff-1234-5678-1234-56789abcdef0` (`useAltUuid` フラグ)

**Characteristics**:
| UUID | Name | Properties | Payload |
|---|---|---|---|
| `e2e5e5e1-...` | Motion | R/W/Notify | JSON `{"type":"bleMotion","pitchServo":{"angle":,"speed":}, "yawServo":{}}` |
| `e2e5e5e2-...` | Avatar | R/W/Notify | JSON `{"type":"bleAvatar","leftEye":{...},"rightEye":{...},"mouth":{...}}` (各 x/y/rotation/weight/size) |
| `e2e5e5e3-...` | Config | R/W/Notify | JSON `{"cmd":"setWifi","data":{"ssid":,"password":}}` 等 + `notifyState` で wifiConnecting/Connected/Failed |
| `e2e5e5e4-...` | RGB | R/W/Notify | JSON `{"leftRgbColor":"#FF0000","leftRgbDuration":0.3,"rightRgbColor":"#00FF00","rightRgbDuration":0.3}` |

**Standard Battery Service** (`0x180F`):
- Battery Level char `0x2A19` (R/Notify, 0-100)

**MTU**: 512 / 最大 payload 2048 (`STACKCHAN_MAX_JSON_LEN`)

### 3.3 Advertise (`bleprph.c:229-313`)
- Device name: `"StackChan"` (固定)
- Adv flags: `BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP`
- 128-bit Service UUID 1 個 (StackChan Service)
- Scan response: name + TX power + manufacturer data `[0xE5, 0x02, MAC[0..5]]` (M5Stack vendor ID)

### 3.4 Pairing (`bleprph.c:443-504`)
- Passkey display + Numeric comparison (just-works **不可**)
- 固定 passkey `123456` がコード内に
- Bonding 有効 (NVS 永続化)
- REPEAT_PAIRING 許可 (古い bond 削除して再ペア)

### 3.5 PC 側 reference (`app/lib/util/blue_util.dart`)
- Flutter + `flutter_blue_plus`
- UUID 定数全部 dart 側に同じ値で hardcode
- WiFi 設定 flow: SSID/pw 入力 → JSON serialize → Config char に write → Config char の notify subscribe → state を UI 反映

---

## 4. 実装プラン (3 Phase)

### Phase 0: BTstack on ESP-IDF v5.4 smoke

**目的**: 「BTstack が ESP-IDF v5.4 + ESP32-S3 上で `gatt_counter` example を 1 個 advertise できる」確証を取る。Phase 1 以降の前提条件。

**手順**:
1. R2P2-ESP32 とは別の作業 dir で empty IDF project 作る
2. `integrate_btstack.py` で BTstack を `$IDF_PATH/components/btstack/` に copy
3. BTstack `port/esp32/example/gatt_counter` (or 同等) を build_config に追加
4. sdkconfig に上記 §1.3 を反映 (特に `CONFIG_BT_CONTROLLER_ENABLED=y` 確認)
5. `idf.py set-target esp32s3` → `idf.py menuconfig` で Bluetooth Controller Enabled を確認 → `idf.py build flash`
6. 物理 reset → 人間の monitor で `BTstack ready!` log 確認
7. Mac 側 `chrome://bluetooth-internals/#devices` か `bleak` (Python は禁止だから Ruby `rb-corebluetooth` か Chrome) で advertise 受信確認

**Risk**: v5.0 → v5.4 で `esp_bt_controller_*` API に微妙な差があれば patch 必要。Phase 0 で早めに当たる。

### Phase 1: picoruby-ble に ESP32 port を追加

**前提**: Phase 0 通過

1. **R2P2-ESP32 fork (`bash0C7/R2P2-ESP32`) に変更**
   - 新 sdkconfig fragment `sdkconfigs/bt_btstack` を §1.3 内容で作成
   - `Rakefile` の `SDKCONFIG_DEFAULTS` 連結に追加 (現状 `sdkconfig.defaults;sdkconfigs/usb_console;sdkconfigs/cores3` → 末尾に `;sdkconfigs/bt_btstack`)
   - `components/btstack/` を idf component として登録 (BTstack vendored の `port/esp32/components/btstack/CMakeLists.txt` を参考に audio exclude で writeup)
   - `components/picoruby-esp32/build_config/xtensa-esp-picoruby.rb` に gem 追加:
     ```ruby
     conf.gem gemdir: '<path>/picoruby/mrbgems/picoruby-ble'
     conf.gem gemdir: '<path>/picoruby/mrbgems/picoruby-ble-uart'  # NUS 採用なら
     ```

2. **picoruby fork (`bash0C7/picoruby` か上流に PR) で `mrbgems/picoruby-ble/ports/esp32/` を新設**
   - `ble.c`: RP2040 版 250 行から
     - delete: Pico SDK include 7 行 + `blink_led` 11 行 = 18 行
     - copy: 残り 232 行 (att_*_callback / packet_handler / heartbeat / BLE_init / BLE_hci_power_control / BLE_gap_local_bd_addr / GATT Client 6 関数)
     - add: `app_main()` 等価部 (`btstack_init()` を最初に呼ぶ初期化フック)
   - `ble_peripheral.c`: 52 行から Pico SDK include 7 行を delete、残り全 copy
   - `ble_central.c`: 53 行から Pico SDK include 7 行を delete、残り全 copy
   - `ble_common.h`: 14 行 ほぼそのまま
   - `mrbgem.rake`: §2.5 draft の platform 分岐で `ports/esp32/*.c` を選択

3. **smoke**: bring-up app.rb を `BLE.new(:peripheral, ...)` で minimal advertise させて、Mac 側 Chrome `chrome://bluetooth-internals` で `StackChan-PicoRuby` 等の名前を観測

4. **`ble_irb` 動作確認** (Web Bluetooth で IRB on BLE)。これが動けば picoruby-ble ESP32 port は production-ready

### Phase 2: stackchan-protocol を BLE に乗せる

**前提**: Phase 1 通過 + プロトコル選定 (§5)

(プロトコル選定によって作業内容が変わる)

---

## 5. プロトコル選定 (要決断)

|  | A. 公式互換 (UUID `e2e5e5*` + JSON) | B. NUS 経由 (`picoruby-ble-uart`) | C. 自前 binary frame (現 stackchan-protocol を NUS 上に) |
|---|---|---|---|
| 既存 Flutter app そのまま動く | ◎ | ✕ | ✕ |
| Web Bluetooth (Chrome) | △ (4 char + JSON) | **◎** (1 service + RX/TX char) | ◯ (NUS 上で自前 frame) |
| Mac 自作 script | ◯ (rb-corebluetooth + JSON) | **◎** | ◯ |
| stack 工数 | 中 (4 char GATT db + JSON parser) | **小** (`BLE::UART` 流用) | 中 (transport 層差替) |
| picoruby 側 JSON parser | 要 | 不要 | 不要 |
| 既存 frame protocol 資産流用 | 部分的 (mapping 必要) | 部分的 | **◎** (そのまま BLE NUS 上に流す) |
| 公式 Switch Science demo 動く | ◎ | ✕ | ✕ |

### 判断材料

- **公式 Flutter app との互換性が欲しい** → A
- **Chrome の Web Bluetooth でデモしたい / Mac script で楽に叩きたい** → B
- **既存 USB-serial 用 stackchan-protocol (Dispatcher / FrameParser / FrameWriter) をそのまま使い回したい** → C
- **両立** → A を Service 1、C (or B) を Service 2 として並行 expose も可能 (BLE は複数 service を同時 advertise できる)

### 推奨

**B (NUS) を Phase 2 の最小到達目標、A (公式互換) を将来オプション** とするのが最短で価値出る:
- `picoruby-ble-uart` は純 Ruby (`mrblib/ble_uart.rb`) で実装済 → port 工数ゼロ
- Chrome から `navigator.bluetooth.requestDevice({filters:[{services:[NUS_UUID]}]})` で即繋がる
- 既存 frame protocol は NUS の RX char に WriteWithoutResponse で投げて、TX char の Notify で受ける形にすれば transport 層の差替だけで済む (C と B のハイブリッド)

→ つまり **B + C のハイブリッド**: NUS の char に既存 frame format を流す。`pc/stackchan-protocol/lib/stackchan_protocol/frame_writer.rb` の transport 層を「`UART#write` → `BLE::UART#write`」に差替えるだけで、`stackchan-control` CLI もほぼ無編集で BLE 化できる。

将来公式 Flutter app 互換が要件化したら Phase 3 で A の GATT を追加 (multi-service advertise) すればよい。

---

## 6. Risk / Unknown / 残作業

| Risk | 対処 |
|---|---|
| BTstack v5.4 controller API 微妙な差 | Phase 0 smoke で早期検出 |
| `btstack_run_loop_freertos` と R2P2 main task の整合 | BTstack を別 task に分離 (`xTaskCreate(btstack_thread, stack=8KB, priority=app_main と同じ)`) |
| WiFi + BLE 同時 RF coex | ESP-IDF が自動 coex。CoreS3 PSRAM 8MB で余裕。当面 BLE 単独 build profile から始める |
| NVS 24KB が BLE bonding と SQL に十分か | 8 device 分の bonding info ~ 数 KB なので 24KB で足りる見込み。問題出たら 32KB へ |
| picoruby-ble の `picoruby-mbedtls` 依存が ESP32 で解決できるか | mbedtls は esp-idf 標準提供なので問題なし。`picoruby-mbedtls` gem 側の wrapper が ESP32 で動くか別途確認 |
| `PICORUBY_PLATFORM` の取得方法 | mrbgem.rake で build_config 名から判定するパターンが picoruby 内に既存例あるか要調査 |

---

## 7. 次のステップ

1. **プロトコル選定** (§5) — ユーザ決断要
2. spec 確定後 plan 作成 (`docs/superpowers/plans/2026-05-XX-ble-bringup.md`):
   - Phase 0 smoke の手順を TDD-able な粒度に分解
   - Phase 1 の port file ごとの diff 提示
3. Phase 0 実機検証 → Phase 1 → Phase 2

---

## Appendix: 参照元

- BTstack ESP32 port: `/Users/bash/dev/src/github.com/picoruby/picoruby/mrbgems/picoruby-r2p2/lib/pico-sdk/lib/btstack/port/esp32/`
  - `README.md`, `integrate_btstack.py`, `template/main/main.c`, `template/sdkconfig`, `components/btstack/btstack_port_esp32.c`, `components/btstack/btstack_tlv_esp32.c`
  - `platform/freertos/btstack_run_loop_freertos.c`
  - `example/ublox_spp_le_counter.c` (advertise + GATT server 最小例)
- picoruby-ble RP2040 port: `/Users/bash/dev/src/github.com/picoruby/picoruby/mrbgems/picoruby-ble/`
  - `include/ble.h` (55行) / `ble_peripheral.h` (20行) / `ble_central.h` (20行)
  - `ports/rp2040/ble.c` (250行) / `ble_peripheral.c` (52行) / `ble_central.c` (53行) / `ble_common.h` (14行)
  - `src/mruby/ble.c` (Ruby ↔ C queue 実装)
  - `mrblib/ble.rb` / `ble_central.rb` / `ble_advertising_data.rb` / `ble_gatt_database.rb`
- StackChan 公式 BLE: `/Users/bash/dev/src/github.com/m5stack/StackChan/firmware/`
  - `sdkconfig.defaults` (NimBLE 選択箇所)
  - `main/hal/hal_ble.cpp` / `main/hal/utils/bleprph/{bleprph.h,bleprph.c,gatt_svr.c}`
- Flutter app reference: `/Users/bash/dev/src/github.com/m5stack/StackChan/app/`
  - `lib/util/blue_util.dart` (UUID 定数), `lib/view/popup/device_wifi_config.dart`, `lib/model/blue_model.dart`
