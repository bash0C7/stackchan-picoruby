---
paths:
  - "build_config/esp32-*"
  - "mrbgems/picoruby-stackchan-robot/**"
  - "mrbgems/picoruby-stackchan-led/**"
  - "mrbgems/picoruby-si12t/**"
  - "mrbgems/picoruby-aw88298/**"
  - "apps/robot/**"
  - "aot/**"
---

# Firmware・Robot Engine・CoreS3ハードウェア制約

## Firmware・Gem・AOT・Robot構成

- **Firmware構成**: gem一覧は`build_config/esp32-stackchan.rb`にあり、`r2p2_build_env`が`R2P2_BUILD_CONFIG`（絶対path）としてR2P2-ESP32に渡す。LCD/PY32/servoのgemは`conf.gem github:`でfetchし、protocol gem（`mrbgems/picoruby-stackchan-protocol`）・AOT kernel・`picoruby-multicore`はgem dirで入れる。R2P2-ESP32は並ぶgemの`ports/esp32/*.c`と`ports/common/*.c`をIDF componentでcompileする。
- **数値表現の一致**: firmwareは`MRB_INT32`+`MRB_WORD_BOXING`+`mruby-bigint`。R2P2-ESP32の`CMakeLists.txt`が同じdefineでCをcompileするため、この3つはconfigと揃える。31bit超のIntegerはheap objectになる。R2P2-ESP32のdefault configにStackChan gemは置かない。
- **Pure Ruby driver gems**: `stackchan-led`・`si12t`・`aw88298`・`drb-ble`・`stackchan-robot`はRakefileが`app.mrb` compile時にappの前へ連結する（先頭にappのtop-level `require`を置く）。
- **AOT kernels（`aot/kernels/*.rb`）**: spinel→suppifyで1つのmrbgemにしてfirmwareに入れる。kernelは`module StackchanAot`の`def self.` method。`ulaw_decode`は`picoruby-multicore`でcore 1、`glyph16`はcore 0からrobot gemの`Kernel#glyph16`経由で呼ぶ。suppifyの`--table multicore_kernels`でVMとcore 1 workerがそれぞれkernelとspinel runtimeの複製を持つため両core同時実行可能。手順と制約は`aot/README.md`。
- **Robot app（`apps/robot/app.rb`）**: `require`列と`StackChan.robot do |bot| … end.run` 1つだけのDSLファイル。`$`・トップレベル`@`・定数は置かない。
- **Robot engine（`mrbgems/picoruby-stackchan-robot`）**: `Robot#run`は`serve(Boot, Peripheral)`で、`sleep_ms 5000`→boot→`sleep_ms 3000`→peripheral→`on_boot`→advertiseの順に進み戻らない（順序は`test/device/robot_run_test.rb`が固定）。class bodyでdevice定数（`ILI9342`/`I2C`/`BLE`等）を読まない。例外は`peripheral.rb`の`< BLE`のみで、host device suiteはこの1ファイルを読まない。

## CoreS3ハードウェア（ESP32-S3 / 16MB Flash / 8MB Quad PSRAM）

- デバイス: ILI9342 320x240、WS2812x12、AXP2101 PMIC、AW9523+PY32 IO expander、BMI270+BMM150、LTR-553、GC0308、フィードバックサーボx2、Si12T頭タッチ3 zone、AW88298+1W speaker、PCF8563 RTC、microSD、NFC。
- ピン配置と初期化順の一次情報源は公式ファームウェア`../StackChan`（`firmware/main/hal/board/`、`hal/drivers/`）。読み取り専用で書き込まない。

### cold-boot初期化順（LCDとWS2812を確実に出す順）

system I2C（SDA=12 / SCL=11）で:
1. **AXP2101 @0x34**: `0x97 0x69 0x30 0x90 0x94 0x95 0x27 0x99`を全部書く（`0x90=0xBF`だけではbacklightが立たない）。
2. **AW9523 @0x58**: P0 output `0b00000111`（WS2812 5V rail）、P1 `0x81 → 20ms → 0x83`（LCD reset）。レジスタ順序はP0→P1→CONFIG_P0→CONFIG_P1→GCR→LEDMODE_P0→LEDMODE_P1。
3. **PY32**: GPIO0（VM_EN）HIGH+200ms、GPIO13（WS2812 data）push-pull。`refresh_leds`はread-modify-write。
4. **ILI9342**: `rst_pin`/`bl_pin`はexpander経由のため未配線GPIOを渡す。
5. **BLE起動前yield**: cold-boot後に`sleep_ms 3000`で必ずyieldしてから`BLE.new`→`start`する（yieldしないとlogは正常でもRFにadvertisingが出ない）。

### デバイス固有の破壊的トラップ

- `mrbgems/picoruby-stackchan-robot/mrblib/stackchan-robot/boot.rb`のPY32 init区間の`puts`（`# REQUIRED FOR PY32 COLD-BOOT`マーカー）は**削除禁止**（bytecode layout依存のcrashを抑えている）。
- **デバイス側に一時的な`puts`を足さない**: cold bootで`Loading app.mrb`直後にGuru Meditationのboot loopへ入ることがあり、USB CDC再列挙でesptoolも繋がらなくなる。復旧は人間によるUSB抜き差しのみで、抜き差し直後の1回しかesptoolが通らない。
- **SPI転送上限4092B**: `picoruby-spi`のESP32 portは`max_transfer_sz`未指定+DMA有効でbusを作るためDMA descriptor 1個分で頭打ちになり、超えると`IOError: SPI write failed`（host fakeでは再現しない）。
- **`picoruby-uart`**: unitは`:ESP32_UART0..2`、`write`はStringのみ、`read`はtimeoutを無視するため`readpartial`でpollする。
