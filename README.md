# stackchan-picoruby

Personal port of [M5Stack StackChan](https://www.switch-science.com/products/11129) (CoreS3 ベース) to [PicoRuby](https://github.com/picoruby/picoruby) on [R2P2-ESP32](https://github.com/picoruby/R2P2-ESP32).

Architecture is **PC ↔ StackChan avatar pattern**:

- **StackChan**: PicoRuby driver 群 + frame protocol で I/O 端末として動作。LCD / LED / (将来) servo / sensor を駆動
- **PC (Mac)**: [`rb-foundation-model-mac`](https://github.com/bash0C7/rb-foundation-model-mac) (Apple Foundation Model の Ruby binding) で AI orchestration

公式 M5Stack firmware は隣ディレクトリ `../StackChan` に **read-only** で置く。ピン配置と init sequence の参照源として使うが、絶対に書き換えない。

## Status (2026-05-14)

bring-up smoke (LCD face + WS2812 RGB ring + 10s heartbeat) が CoreS3 実機で確認済 (`feature/stackchan-display-bringup` branch、tip `f50780e`)。

| Subsystem | State | Driver mrbgem |
| --- | --- | --- |
| LCD (ILI9342) | working | `mrbgems/picoruby-ili9342` |
| Face render (Neutral / Happy / Sad) | working | `mrbgems/picoruby-stackchan-protocol` (Face module) |
| RGB LED ring (WS2812 ×12, 4-mode animator) | working | `mrbgems/picoruby-stackchan-led` |
| PY32 IO Expander (I2C, RMW LED refresh + digital_write) | working | `mrbgems/picoruby-py32-io-expander` |
| USB-Serial host frame protocol (Dispatcher / FrameParser) | working | `mrbgems/picoruby-stackchan-protocol` |
| PC-side CLI (`stackchan-control` / `picomodem-upload`) | working | `pc/stackchan-protocol/` |
| **Mac comm (WiFi station + TCP/HTTP/WebSocket)** | **next** | upstream `picoruby-esp32` + `picoruby-socket` + `picoruby-net-*` |
| IMU (BMI270 + BMM150) | not started | `picoruby-bmi270` (planned) |
| Servo (SCServo, neck pan + tilt) | not started | `picoruby-scservo` (planned) |
| Touch (3-zone Si12T head) | not started | (planned) |
| Camera / Mic / Speaker | unscoped | far future |
| BLE-Serial | **deferred** (R2P2-ESP32 sdkconfig に BT 設定無し、`picoruby-ble` の ESP32 port 不明) | — |

### Hardware finding (CoreS3 bring-up)

cold-boot で LCD と LED を出すには **ESP32 SoC の SPI/GPIO init だけでは不足**。以下を順に叩く必要あり:

1. **AXP2101 PMIC**: `0x97 / 0x69 / 0x30 / 0x90 / 0x94 / 0x95 / 0x27 / 0x99` を全部書く (ALDO/BLDO の rail を立てる)。`0x90 = 0xBF` だけでは LCD バックライト点かない
2. **AW9523 GPIO Expander**: `reg 0x02 (P0) = 0b00000111` で **WS2812 用 5V rail を enable**。これ書かないと WS2812 chip 側を完璧に叩いても暗黒
3. **PY32 GPIO 0 (VM_EN) HIGH + 200ms settle**: WS2812 data line (PY32 GPIO 13) を駆動する前に必須
4. WS2812 への書き込みは `refresh_leds` を read-modify-write 必須 (count を wipe しない)

## Repository layout

```
stackchan-picoruby/
├── Rakefile                              # r2p2:* tasks (build / flash / upload / send_* / verify_*)
├── docs/superpowers/
│   ├── specs/   ← per-subproject design docs + handoff memo
│   └── plans/   ← per-subproject implementation plans
├── mrbgems/
│   ├── picoruby-ili9342/                 # LCD driver (ILI9342 SPI)
│   ├── picoruby-py32-io-expander/        # PY32 chip driver (digital_write + RMW refresh_leds)
│   ├── picoruby-stackchan-led/           # WS2812 12-LED ring driver on top of PY32
│   └── picoruby-stackchan-protocol/      # Frame parser + Dispatcher + Face module + bring-up app.rb
└── pc/stackchan-protocol/
    ├── lib/stackchan_protocol/           # FrameWriter, LedColorTable, etc.
    └── exe/
        ├── stackchan-control             # PC CLI (face/led/raw/combo)
        └── picomodem-upload              # PicoModem ファイル uploader (Ruby + uart gem + handshake responder)
```

各 `mrbgems/picoruby-*` は standalone PicoRuby gem の構造 (mrbgem.rake / Rakefile / mrblib / sig / test / examples) に揃えてあり、stable になったら個別リポジトリに切り出して upstream PR に出せる。

## Build + flash (CoreS3)

`Rakefile` に `r2p2:*` タスク群を集約。隣リポジトリ `../../bash0C7/R2P2-ESP32` 呼び出しと esp-idf env source を全部ラップしてある。

| Task | 用途 |
| --- | --- |
| `rake r2p2:setup` | 初回・target 切り替え後 (deep_clean + mruby host rebuild + `idf.py set-target esp32s3`)。10〜20 分 |
| `rake r2p2:build_flash` | **基本フロー**。`picoruby:build → flash` を 1 screen 内で連結 |
| `rake r2p2:rebuild_gems` | gem の `.rb` を再生成したい時 (libmruby.a を消すだけ) |
| `rake r2p2:upload SRC=path/to/app.rb` | PicoModem 経由で `/home/app.rb` 上書き |
| `rake r2p2:send_face NAME=neutral` | Face frame 送信 |
| `rake r2p2:send_led COLOR=red MODE=solid` | LED 制御 frame 送信 |
| `rake r2p2:verify_led` | reset + capture + send_led + tail log の one-shot |
| `rake r2p2:reset` | RTS pulse (CoreS3 の native USB-CDC では chip reset は効かないこと注意、人間に物理ボタン依頼が確実) |

### CoreS3 固有の sdkconfig (R2P2-ESP32 側)

- `sdkconfigs/cores3`: `SPIRAM=y` + `SPIRAM_MODE_QUAD=y` + `SPIRAM_SPEED_80M=y`。CoreS3 は Quad PSRAM 8MB (Octal でない)
- `sdkconfig.defaults`: `CONFIG_ESPTOOLPY_FLASHSIZE_16MB=y`
- `SDKCONFIG_DEFAULTS=sdkconfig.defaults;sdkconfigs/usb_console;sdkconfigs/cores3` (Rakefile にハードコード)

## License

MIT for code originating in this repository. The official `m5stack/StackChan` repository — referenced for pin numbers and init sequences — has its own license; see `docs/upstream-license-note.md`.
