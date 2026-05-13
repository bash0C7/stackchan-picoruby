# stackchan-picoruby

Personal port of [M5Stack StackChan](https://www.switch-science.com/products/11129) to [PicoRuby](https://github.com/picoruby/picoruby) on [R2P2-ESP32](https://github.com/picoruby/R2P2-ESP32). Architecture is "PC ↔ StackChan via serial": StackChan runs PicoRuby drivers and serves as I/O peripheral, while a host Ruby program (using local Apple Foundation Model) does the AI orchestration.

The official M5Stack firmware lives in the sibling directory `../StackChan` and is treated **read-only** — pin numbers and init sequences are referenced from there but never modified.

## Status (2026-05)

| Subsystem | State | Driver mrbgem |
| --- | --- | --- |
| LCD (ILI9342) | host-tested, hardware-untested | `mrbgems/picoruby-ili9342` |
| Face render (3 expressions) | host-tested, hardware-untested | — |
| USB-Serial host protocol (1-byte) | host-tested, hardware-untested | `mrbgems/picoruby-stackchan-protocol` |
| IMU (BMI270) | not started | `picoruby-bmi270` (planned) |
| Servo (SCServo) | not started | `picoruby-scservo` (planned) |
| Touch (FT6336) | not started | `picoruby-ft6336` (planned) |
| RGB LED (SK6812) | not started | wrapper of upstream `adafruit_sk6812` (planned) |
| BLE-Serial | not started, blocking on ESP32 BLE port | (long-term) |
| Camera / Mic / Speaker | unscoped | far future |

## Repository layout

```
stackchan-picoruby/
├── docs/superpowers/
│   ├── specs/   ← per-subproject design docs
│   └── plans/   ← per-subproject implementation plans
└── mrbgems/
    └── picoruby-ili9342/
        ├── mrblib/, sig/, test/, examples/
        ├── docs/cores3-pinout-and-init.md
        └── README.md
```

Each `mrbgems/picoruby-*` directory is shaped like a standalone PicoRuby gem (mrbgem.rake / Rakefile / mrblib / sig / test / examples), so it can be split into its own repository for upstream PR submission once stable.

## Build + flash (CoreS3)

See `mrbgems/picoruby-ili9342/README.md` for the per-driver usage. The recipe to flash a CoreS3 with this monorepo's gems wired in:

```bash
cd /Users/bash/dev/src/github.com/bash0C7/R2P2-ESP32
export SDKCONFIG_DEFAULTS="sdkconfigs/usb_console;sdkconfigs/spiram"
rake setup_esp32s3
rake build && rake flash
rake monitor
```

`bash0C7/R2P2-ESP32` carries the build hooks for this monorepo on the `feature/cores3-stackchan` branch.

## License

MIT for code originating in this repository. The official `m5stack/StackChan` repository — referenced for pin numbers and init sequences — has its own license; see `docs/upstream-license-note.md`.
