# Handoff: Phase 1 BLE on PicoRuby が setup hang で詰まり中

> 作成 2026-05-15。次セッション開始時に頭から読むこと。Phase 0 (BTstack ESP-IDF v5.4 advertise smoke) は完了 + commit 済。Phase 1 (picoruby-ble の ESP32 port + R2P2 統合) が **r2p2:setup の host mruby build phase で hang**。

## TL;DR

- Phase 0 = ✅ 完了。CoreS3 で BTstack init + advertise enable まで実機確認済 (BD_ADDR `44:1B:F6:E2:05:66`)。 R2P2-ESP32 commit `5e9f73b`、stackchan-picoruby commit `8284f1b`。
- Phase 1 で port file を nested R2P2 picoruby tree にミラー + idf component CMakeLists に SRCS 追加までやった所で `rake r2p2:setup` が **25 分 timeout で hang** (picoruby-yaml 周りのログ後)。
- 仮説: `picoruby-ble/mrbgem.rake` の `case build.name` 分岐に **host build (build.name == 'host') の case が無い**。host build で `else` 経由 `picoruby-cyw43` dep 要求されて hang。
- **次 session 最初の動き**: working picoruby tree (`/Users/bash/dev/src/github.com/picoruby/picoruby/`) を一旦 reset (master に戻す) で working tree の混乱を解消、mrbgem.rake を host case 含めて書き直し、setup retry。

## 現状: 各 repo の dirty state

### `bash0C7/R2P2-ESP32` (branch: `feature/ble-bringup`、tip `5e9f73b`)
```
 M components/picoruby-esp32/CMakeLists.txt          # SRCS に ble port .c 4 個 + INCLUDE_DIRS + PRIV_REQUIRES btstack 追加
 M components/picoruby-esp32/build_config/xtensa-esp-picoruby.rb  # picoruby-ble + picoruby-ble-uart の gemdir 追加 (nested tree path)
 m components/picoruby-esp32/picoruby                # ← submodule、内部に dirty (下記)
 M sdkconfigs/bt_btstack                              # CONFIG_BTSTACK_SMOKE=y → n
```

### nested picoruby tree (`R2P2-ESP32/components/picoruby-esp32/picoruby/`、submodule)
```
 M mrbgems/picoruby-ble/mrbgem.rake                  # case build.name 分岐版 (esp32 case は noop、else は cyw43 dep)
?? mrbgems/picoruby-ble/ports/esp32/                 # 6 ファイル: ble_common.h, btstack_owner.{h,c}, ble.c, ble_peripheral.c, ble_central.c
```

### working picoruby tree (`/Users/bash/dev/src/github.com/picoruby/picoruby/`、branch: `feature/ble-esp32-port`)
```
 M mrbgems/picoruby-ble/mrbgem.rake                  # 古い `spec.objs += ...` 版 (× 間違い)
?? .claude/                                           # 関係なし
?? mrbgems/picoruby-ble/ports/esp32/                 # 同じ 6 ファイル
```

**重要**: build pipeline が **使うのは nested tree** のみ。working tree は build に reach しない。working tree を **master に reset** して clean にしても build pipeline は影響無い (nested tree が source of truth)。

### `bash0C7/stackchan-picoruby` (branch: `feature/ble-bringup`、tip `8284f1b`)
```
clean (Phase 0 commit 済以降 touch してない)
```

## Phase 1 で既に終わってる作業 (TaskList #23-#29 完了)

1. ports/esp32/ble_common.h
2. ports/esp32/btstack_owner.{h,c}
3. ports/esp32/ble.c (RP2040 から copy + Pico SDK includes 削除 + `picoruby_btstack_ensure_started()` 呼出 + blink_led 削除)
4. ports/esp32/ble_peripheral.c + ble_central.c (RP2040 から copy + Pico SDK includes 削除のみ)
5. mrbgem.rake で `case build.name` 分岐 (esp32 case は noop、port .c は idf component 側でコンパイル)
6. xtensa-esp-picoruby.rb に picoruby-ble + picoruby-ble-uart の gemdir 追加 (`#{__dir__}/../picoruby/...`)
7. sdkconfigs/bt_btstack の CONFIG_BTSTACK_SMOKE=n
8. picoruby-esp32/CMakeLists.txt に SRCS (ble port .c × 4) + INCLUDE_DIRS + PRIV_REQUIRES btstack 追加

## 詰まってるポイント

`rake r2p2:setup` が host mruby build の途中 (`picoruby-yaml` の処理後) で 25 分 timeout。subagent log の最後:
```
-- Configuring done (3.2s)
-- Generating done (0.3s)
-- Build files have been written to: /Users/bash/dev/src/github.com/bash0C7/R2P2-ESP32/build
```
の後で no progress。

仮説 (順序):

1. **mrbgem.rake の host build 分岐欠落 (最有力)**: 現状の mrbgem.rake は
   ```ruby
   if build.name =~ /xtensa-esp|esp32/
     # esp32 case: noop
   else
     spec.add_dependency 'picoruby-cyw43'
   end
   ```
   `build.name == 'host'` は else に入って picoruby-cyw43 を要求 → host で cyw43 が読めず loop or 無限 wait の可能性。

2. **gem path の relative 解決問題**: `"#{__dir__}/../picoruby/mrbgems/picoruby-ble"` の `__dir__` が build 文脈でどう解決されるか。本来は build_config の置き場 = `R2P2-ESP32/components/picoruby-esp32/build_config/`。`#{__dir__}/../picoruby/...` = `R2P2-ESP32/components/picoruby-esp32/picoruby/...` = nested tree。OK のはず。だが別 evaluation 文脈なら違う path に向く可能性。

3. **mruby host build の不整合**: nested tree の commit base (`414627fd Fix build_config: picoruby->femtoruby`) と picoruby-ble gem 間で何か不整合。

## 推奨次手 (次 session の最初の動き)

### A. 一旦クリーンに戻す (~5 分)

```
# 1. working picoruby tree を master に reset (混乱回避、build に影響しない)
cd /Users/bash/dev/src/github.com/picoruby/picoruby
git checkout -- mrbgems/picoruby-ble/mrbgem.rake
rm -rf mrbgems/picoruby-ble/ports/esp32
git checkout master
git branch -D feature/ble-esp32-port
# .claude/ untracked は無関係なので無視

# 2. nested tree の状態確認
cd /Users/bash/dev/src/github.com/bash0C7/R2P2-ESP32/components/picoruby-esp32/picoruby
git status --short
# 期待: M mrbgem.rake + ?? ports/esp32/
```

### B. mrbgem.rake に host case を追加して setup retry

nested tree の `R2P2-ESP32/components/picoruby-esp32/picoruby/mrbgems/picoruby-ble/mrbgem.rake` を以下に書き換え:

```ruby
MRuby::Gem::Specification.new('picoruby-ble') do |spec|
  spec.license = 'MIT'
  spec.authors = ['HASUMI Hitoshi', 'bash0C7']
  spec.summary = 'BLE class — peripheral / central / broadcaster / observer'

  if build.name == 'host'
    # Host (picorbc compiler) build: no real BT stack on host. Skip deps too.
    # mruby class binding files (src/*.c) are auto-picked up by mruby gem rules.
  elsif build.name =~ /xtensa-esp|esp32/
    spec.add_dependency 'picoruby-mbedtls'
    # Port .c files compiled by R2P2-ESP32's picoruby-esp32 idf component CMakeLists.txt.
  else
    # RP2040 / femtoruby. Port files via picoruby-r2p2/cmake/CMakeLists.txt glob.
    spec.add_dependency 'picoruby-mbedtls'
    spec.add_dependency 'picoruby-cyw43'
  end
end
```

そして `rake r2p2:setup` を subagent (haiku, foreground, timeout 30 分) で再実行。

### C. それでも hang なら debug 経路

- `rake r2p2:setup` を **bash run_in_background** で起動し、log を tail で peek。CLAUDE.md の「rake は subagent foreground」は debug 段階では例外的に背景化 OK と判断。
- 具体的に何の gem を処理してる時に hang するか特定する。

### D. setup OK なら build → flash → verify の Plan Task 1.9-1.12 を順次

期待される build エラーパターン (Plan Task 1.9 表):
| Symptom | Likely fix |
|---|---|
| `unknown type name 'hci_con_handle_t'` | INCLUDE_DIRS に btstack header 不足 |
| `multiple definition of 'btstack_main'` | Phase 0 smoke 残ってる (Task 1.7 確認) |
| `undefined reference to 'BLE_*'` | port files が build に入ってない |

### E. Phase 1 commit (Plan Task 1.13)

3 repo:
1. **nested picoruby tree (submodule)**: `mrbgems/picoruby-ble/{ports/esp32, mrbgem.rake}` を commit、submodule pointer を R2P2-ESP32 で update
2. **R2P2-ESP32**: `components/picoruby-esp32/CMakeLists.txt`, `build_config/xtensa-esp-picoruby.rb`, `sdkconfigs/bt_btstack`, submodule pointer を commit
3. **stackchan-picoruby**: `examples/ble_smoke.rb` (Task 1.11 で作る)

## TaskList 状態

#23-#29 = completed (Phase 1 task 1.1-1.7)
#30 = in_progress (Task 1.8 r2p2:setup) ← ここで hang
#31-#35 = pending (Task 1.9-1.13)
#20-#22, #36 = pending Spec amendment 4 件

## Spec amendment が溜まってる (#20, #21, #22, #36)

Phase 0 / Phase 1 で発見した plan の bug / unspecified 事項:
- #20: `NVM_NUM_DEVICE_DB_ENTRIES` macro が btstack_config.h に必要 (le_device_db_tlv.c 要求)
- #21: btstack_smoke.c に `#include "btstack_port_esp32.h"` 必要 (btstack_init 宣言のため)
- #22: build cache desync trap (sdkconfig フラグ flip 時に `rm -rf build/esp-idf/main` で main.c.obj を強制 rebuild)
- #36: mrbgem.rake API は `spec.cc.files <<` でなく `spec.objs += Dir.glob(...).map { ... pathmap("#{build_dir}/%X.o") }` (mbedtls pattern)

これらは Phase 1 完走後にまとめて spec/plan に追記する予定。

## Phase 0 で発見した bring-up 知見 (CLAUDE.md に既に記録済)

- BTstack vendored ESP32 port の v5.4 適合 patch 4 件は commit `5e9f73b` の message に articulate 済。
- build cache desync の検知方法: `xtensa-esp32s3-elf-objdump -d build/R2P2-ESP32.elf` で app_main の size を見る (期待 11 byte = entry + 2 call + retw.n)。

## 副次の悩み (debug を粘る前の一般的注意)

- **boot log の compile time 必ず確認**: `Compile time: May 15 2026 HH:MM:SS` が flash した build の時刻と一致してるか。古い時刻なら flash されてない or monitor の log buffer 見てる。
- **monitor 経由が確実**: cat /dev/cu.usbmodem* > log は USB-CDC reset で 0 byte で死ぬ。CLAUDE.md ガイド通り人間に monitor 立ち上げ依頼。
- **Mac 側 BLE scan の cache**: 過去 advertise した name を Mac の BT cache が持ってて新 advertise が遅延 visible する事あり。System Settings > Bluetooth で device を一旦 forget するとよい。

## 関連リンク

- Phase 0 / Phase 1 全体 plan: `docs/superpowers/plans/2026-05-15-ble-on-cores3.md`
- BLE bringup spec: `docs/superpowers/specs/2026-05-15-ble-bringup-trace.md`
- 前回 handoff (Phase 0 着手前): `docs/superpowers/specs/2026-05-14-handoff-mac-comm-and-refactor.md`
