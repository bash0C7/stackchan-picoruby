# Handoff: Phase 1 BLE 「device-side log は OK、RF は空中に出てへん」状態

> 作成 2026-05-15。次セッション開始時に頭から読むこと。Phase 1 で device-side `[ble_smoke] HCI WORKING — advertising` まで進んだが、**Mac 2 台で BLE scan しても見えない**ことが判明 → そもそも radio が空中に出てへん疑い濃厚。

## TL;DR — 何が本当に分かっていて、何が誤解だったか

### 動いてる (確定)

- `picoruby-ble` の ESP32 port 化 + R2P2-ESP32 統合 → build / flash / autostart 通る
- ble_smoke.rb (Ruby 側) が `BLE.new(:peripheral, profile_data)` → `ble.start(60_000)` まで例外無しで実行される
- panic 完全消滅 (LoadError / NameError / coex_schm_lock crash すべて修正済)
- device 側 monitor log:
  ```
  Loading app.rb
  [ble_smoke] init
  I (1836) BLE_INIT: Bluetooth MAC: 44:1b:f6:e2:05:66
  BTstack up and running at 44:1B:F6:E2:05:66
  [ble_smoke] start (60s)
  [ble_smoke] HCI WORKING — advertising as 'StackChan-PicoRuby'
  ```

### 動いてない (確定)

- **Mac 2 台で BLE scan しても `StackChan-PicoRuby` が見えない**
- **Chrome `chrome://bluetooth-internals/#adapter` の Start Discovery が `Failed to start discovery session` を返す** (一方の Mac で確認)

### 重要な誤解 (esa post 292 で要修正)

**Phase 0 で「Mac から visible 確認済」と書いていたが事実誤認**。Phase 0 ハンドオフ doc にも `BTstack init + advertise enable まで実機確認済` としか書いておらず、device 側ログ (`BTstack up and running`) を見ただけ。Mac から実際に scan して見えた事は **一度もない**。

つまり Phase 0 も Phase 1 も device 側 controller↔host link が立った所までしか確認しておらず、**radio が実際に 2.4GHz の空中に乗っているかは検証していない**。

→ esa post https://bist.esa.io/posts/292 はこの修正をして update する必要あり。

## 次セッションでやること (優先順)

### 1. esa post 292 の事実修正

「Phase 0 で Mac visible 確認済 / Phase 1 残課題 = Mac 側 stack 」の記述を「Phase 0 含めて device-side HCI link しか検証してない / Phase 1 残課題 = 実 radio TX」に書き直す。`permanent_memory_update` で number=292 を update。

### 2. coex 設定を最小限に絞る

現状 `sdkconfigs/bt_btstack` で **3 つ全部 `=n`** にしている:

```
CONFIG_SW_COEXIST_ENABLE=n
CONFIG_ESP_COEX_SW_COEXIST_ENABLE=n
CONFIG_ESP_COEX_ENABLED=n
```

`CONFIG_ESP_COEX_ENABLED=n` は **coex component 全体を build から除外**する。これが `coex_pre_init` (ESP_SYSTEM_INIT_FN at priority 204) も skip させていて、その中で **PHY / radio の前段初期化に必要な物** まで消してる可能性がある。

試す:

1. **`CONFIG_ESP_COEX_ENABLED=y` に戻す**
2. **`CONFIG_SW_COEXIST_ENABLE=n` だけ残す** (これで `bt.c` 内 `coex_schm_status_bit_clear_wrapper` 等は no-op になり crash 経路は閉じる、けど `coex_pre_init` 自体は走る)
3. build → flash (auto-regen は Rakefile で効くから fragment 編集だけで OK)
4. `bin/capture-with-pty 30 /tmp/boot.log rake r2p2:monitor` で起動ログ採取
5. crash 出てへんことと device-side `HCI WORKING` ログまで再確認
6. Mac / iPhone (nRF Connect) で scan、見えるか

### 3. それでもダメなら radio 設定を疑う

`sdkconfig` から TX power / channel / advertise 系を grep:

```bash
grep -E "TX_POWER|ADV_CHAN|BLE_PWR" /Users/bash/dev/src/github.com/bash0C7/R2P2-ESP32/sdkconfig
```

特に `CONFIG_BT_CTRL_DFT_TX_POWER_LEVEL` が `P0` (=0dBm) より低かったら明示的に上げる。

ble_smoke.rb / `BLE_peripheral_advertise` 側でも:
- `adv_int_min/max = 800` (= 500ms) → adv 間隔が長すぎて scanner 取りこぼし可能性。`adv_int = 100` (= 62.5ms) ぐらいに短くしてみる
- `channel_map = 0x07` (all 3 advertising channels) は OK
- `adv_type = connectable=true → 0 (ADV_IND)` は OK

### 4. RF 直接確認 (もし scanner で見えないままなら)

- 別のスマホで BLE scanner (nRF Connect 推奨、iPhone なら LightBlue) — Mac BT stack より検出力高い
- ESP32-S3 の **Bluetooth LE-only モード時にアンテナが内蔵か外付け必要か** を CoreS3 データシート / 公式 schematic で確認 (`m5stack/StackChan` リポジトリの datasheet 系。CLAUDE.md 関連リポジトリ節に path あり)
- 公式 firmware (NimBLE) を `m5stack/StackChan/firmware/` から build / flash して比較。それが Mac から見えるなら radio HW は問題なく、BTstack 側の問題

### 5. 上記が解決した後の Phase 1 commit (Task #4)

3 repo:
1. **nested picoruby tree** (`bash0C7/picoruby` fork): `mrbgems/picoruby-ble/{ports/esp32/*, mrbgem.rake, mrblib/ble.rb}` を commit、submodule pointer を R2P2-ESP32 で update
2. **R2P2-ESP32**: `components/picoruby-esp32/CMakeLists.txt`, `build_config/xtensa-esp-picoruby.rb`, `sdkconfigs/bt_btstack`, submodule pointer, `.gitmodules` を commit
3. **stackchan-picoruby**: `examples/ble_smoke.rb`, `bin/capture-with-pty`, `Rakefile` (ensure_sdkconfig_fresh)、`CLAUDE.md` 更新、handoff docs

### 6. Phase 2 着手

Mac から見える状態を達成したら、ble_smoke.rb を **GATT service 持った双方向通信** に拡張して PC↔CoreS3 の経路を完成させる。

## 現状: 各 repo の dirty state

```
bash0C7/picoruby (working tree at ~/dev/src/github.com/picoruby/picoruby/、branch=master)
  M mrbgems/picoruby-ble/mrblib/ble.rb         (cyw43 require を begin/rescue + CYW43.init を const_defined? ガード)
  ?? mrbgems/picoruby-ble/ports/esp32/         (これは nested tree 側に居る、working tree は何も無いはず — 確認)
  remotes: origin=bash0C7/picoruby (push可) / upstream=picoruby/picoruby

bash0C7/R2P2-ESP32 (branch=feature/ble-bringup、tip=5e9f73b)
  M .gitmodules                                                (picoruby submodule URL を bash0C7/picoruby に変更)
  M components/picoruby-esp32/CMakeLists.txt                   (ports/esp32/*.c 追加、PRIV_REQUIRES btstack)
  M components/picoruby-esp32/build_config/xtensa-esp-picoruby.rb  (picoruby-ble + picoruby-ble-uart 追加)
  m components/picoruby-esp32/picoruby                          (nested submodule dirty; 下記)
  M sdkconfigs/bt_btstack                                       (CONFIG_BTSTACK_SMOKE=n + COEX 3 flag を n)
  remotes: origin=bash0C7/R2P2-ESP32 / upstream=picoruby/R2P2-ESP32

  nested picoruby submodule (R2P2-ESP32/components/picoruby-esp32/picoruby/、@414627fd):
    M mrbgems/picoruby-ble/mrbgem.rake                          (host case + esp32 case + RP2040 case 分岐版)
    M mrbgems/picoruby-ble/mrblib/ble.rb                        (working tree と同内容: cyw43 require rescue + CYW43.init const_defined? ガード)
    ?? mrbgems/picoruby-ble/ports/esp32/                        (新規 7 ファイル: ble_common.h, btstack_owner.{h,c}, ble.c, ble_peripheral.c, ble_central.c)
    remotes: origin=bash0C7/picoruby / upstream=picoruby/picoruby

bash0C7/stackchan-picoruby (branch=feature/ble-bringup、tip=8284f1b)
  ?? bin/capture-with-pty                                       (新規: expect 経由で rake r2p2:monitor 完結 capture)
  M Rakefile                                                    (ensure_sdkconfig_fresh + r2p2:build/r2p2:build_flash に組込)
  M CLAUDE.md                                                   (bring-up 5 知見追記: COEX, sdkconfig 再生成, BTstack thread safety, storage wipe, capture-with-pty)
  ?? docs/superpowers/specs/2026-05-15-ble-phase1-handoff.md   (前 handoff、setup hang までの内容)
  ?? docs/superpowers/specs/2026-05-15-ble-phase1-rf-not-emitting-handoff.md  (この文書)
  ?? mrbgems/picoruby-stackchan-protocol/examples/ble_smoke.rb (新規: Phase 1 advertise smoke)
  remotes: origin=bash0C7/stackchan-picoruby (private, GitHub 上にこのセッションで作成)
```

## 既に解決した 5 つの sub-bug (CLAUDE.md にも記録済)

1. **host build phase hang** ← mrbgem.rake に host case 追加
2. **`LoadError: cyw43`** ← `require 'cyw43'` を `begin/rescue LoadError` で囲む
3. **`NameError: BLE::AdvertisingData`** ← 上記 1 の連鎖 (rescue で解消)
4. **BTstack thread safety violation** ← `btstack_owner.c` に setup callback + `picoruby_btstack_run_sync` API、`BLE_init` / `BLE_hci_power_control` / `BLE_peripheral_advertise` を btstack thread に dispatch
5. **`coex_schm_lock` LoadProhibited** ← `sdkconfigs/bt_btstack` で `CONFIG_SW_COEXIST_ENABLE=n` 他

(全部 device-side の話で、RF emit までは到達してない)

## 検証 helper

```bash
bin/capture-with-pty 30 /tmp/boot.log rake r2p2:monitor
# → 30秒 boot log を /tmp/boot.log に captures、Ctrl-] 自動送出して exit
```

Mac 視認用は手動 (System Settings → Bluetooth、もしくは Chrome bluetooth-internals#devices)、もしくは iPhone nRF Connect。

## 関連リンク

- esa post (要修正): https://bist.esa.io/posts/292
- Phase 0 / Phase 1 全体 plan: `docs/superpowers/plans/2026-05-15-ble-on-cores3.md`
- 前回 handoff (setup hang まで): `docs/superpowers/specs/2026-05-15-ble-phase1-handoff.md`
- BLE bringup spec: `docs/superpowers/specs/2026-05-15-ble-bringup-trace.md`
- M5 公式 firmware (NimBLE 利用): `/Users/bash/dev/src/github.com/m5stack/StackChan/firmware/`
- M5 datasheet ref: https://docs.m5stack.com/en/stackchan
