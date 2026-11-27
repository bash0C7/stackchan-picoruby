---
paths:
  - "Rakefile"
  - "lib/**"
  - "acceptance/**"
  - "build_config/**"
  - "tools/**"
---

# Firmware Build・QEMU Gate・Serial・Deploy制約

## QEMU Boot Gate

- firmware焼きtask（`r2p2:flash` / `build_flash` / `build_flash_appmrb`、それを呼ぶ`full_rebuild`・`acceptance:deploy`）と`acceptance:app`は先に`r2p2:qemu_check`を通す。
- QEMUはUART console付きでappの`require`・bundle済みgem（`Peripheral < BLE`含む）・`run`を空にした`StackChan::Robot`によるDSL評価までを検証し、`-icount shift=2,align=off,sleep=off -seed 1 -rtc clock=vm`で決定論的verdictを出す。FAILならflashせず、PASS後にclean buildしてからflashする。
- QEMUが検証しない範囲（cold-boot本体・I2C・LCD・サーボ・スピーカー・BLE無線）は`/stackchan-device-acceptance`が担う。
- `rake qemu:setup`はQEMU `esp_develop_9.2.2_20250817`をsha256 pinで`build/qemu/`に展開する（macOSは`brew install libgcrypt glib pixman sdl2 libslirp`必須）。QEMU `9.0.0`はPSRAM不可。eFuse driveは`nvram.esp32s3.efuse`に`BLK_VERSION_MAJOR=1`（byte 64=`0x01`）が必要。buildとgateの`PICORB_VM`を一致させる。

## Build・Upload・Storage規約

- **`.rb`直接upload禁止**: 必ずhostで`picorbc` compileした`.mrb`を上げる（on-device compileはcodegen stack overflow）。
- **`main_task.rb`とwipe順**: `/home/app.mrb`を無条件`load`し戻らないため`$shell.start`に到達しない（抜けるkeypressもCtrl-C復帰も無い）。`upload_appmrb`は先に`wipe_storage`を通す。`upload_mrb`（`DST=`）はwipeできないため、autostart中deviceへのhelper uploadはwipe→helper→app.mrbの順。
- **clean build必須**: `clean_picoruby_build`依存を外さない。undefined symbolはsource treeをgrepし、無ければobject陳腐化。
- **gem追加とshallow clone保護**: `build_config/esp32-stackchan.rb`にgemを足したら`r2p2:setup`が必要。`conf.gem`のgemは`build/repos/`に`--depth 1` cacheされ自動pullされない。ずれは`tools/check_deps_pushed.sh`が検出し戻れるcommit列（`git branch keep-<sha>`→`fetch --depth 1`→`checkout --detach`）を出す。`build/repos/`に`rm -rf`は使わない（PreToolUse hookでブロック）。
- **sdkconfig**: fragment編集時は`ensure_sdkconfig_fresh`がrake側で処理する。CoreS3は`sdkconfigs/cores3`（Quad PSRAM）。BLE-only buildはcoexを全`n`にしないと`coex_schm_lock`でpanicする。
- **flashとstorage**: `idf.py flash`はstorage区画も焼くため`/home/app.mrb`が消える。flash後はuploadし直す。storage eraseはpartition table依存のため手打ちせず`r2p2:wipe_storage`を通す。
- **ESP-IDF**: `~/esp/esp-idf`を既定とする（`ESP_IDF_EXPORT`で変更）。versionはfirmware workflow image tagがpinし、python venvは名前でなくversionで探す。

## USB Serial・Lock・Capture

- **板の特定**: CoreS3のserialをgitignore済み`.stackchan-usb-serial`（または`STACKCHAN_USB_SERIAL=`）に置き、rakeごとに`ioreg`でserialからportを引く（portは開かない）。全ESP32-S3が同名`USB JTAG/serial debug unit`で列挙され`usbmodemNNN`はlocationID依存のため、glob・製品名・port名保存で特定しない。不一致・不在時は推測せず止まる。確認は`bundle exec rake r2p2:boards`。
- **device lock**: serialを開くrakeは`~/.cache/r2p2-device-locks/esp32.lock`を取る（持ち主pid死亡時は奪取）。acceptanceはstepごとにlockを取り、子rakeには`ESPPORT`とserialをenvで明示渡しする（`Bundler.with_unbundled_env`が起動時環境へ戻すため後付け`ENV`は届かない）。
- **flash identityとboot判定**: `r2p2:flash_identity`がstorage offset（`0x410000`）と`App version`をflashからread-onlyで読む（板はresetする）。reset後のUSB再列挙速度次第でbootloader出力が欠けるため、boot logは`[application] boot`/`[boot] step:` markerとfaultで判定する。別treeのfirmwareなら`/stackchan-device-firmware`で`full-rebuild`（実機上書きdeployは承認済み）。
- **capture後のROM download mode残留**: `r2p2:capture_resilient`/`reset_and_capture`/`bin/capture-with-pty`は終了時にchipをROM download modeに残す（USB列挙されたままadvertisingだけ消える）。capture後にBLEを使うなら必ず`r2p2:reset`を撃って起動を待つ。
- **monitor排他・PTY**: serial portを触るrakeは`ensure_no_concurrent_monitor`を呼ぶ。captureは`bin/capture-with-pty`のみ、生`cat`禁止（PreToolUse hookでブロック）。R2P2 `$>`はPOSIX風shell、Ruby式は`irb`内で実行。
