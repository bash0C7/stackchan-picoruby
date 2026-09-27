# QEMU boot gate — design

## Goal

No firmware reaches the robot unless the same source tree boots under QEMU and loads what the robot
app loads. The gate is deterministic: pinned emulator, fixed eFuse bytes, a probe generated from
the repo, a verdict read from the boot log.

Success:

- `rake r2p2:build_flash` (and everything that chains it: `full_rebuild`, the device trial's arms)
  builds, runs the QEMU gate, and flashes only on PASS.
- The gate FAILs on a tree whose on-device Ruby names a class the firmware lacks (the protocol
  fold-in's `Regexp` at `4aec1d0` / R2P2-ESP32 `f0a8225`) and PASSes on the fixed tree.
- `firmware.yml` runs the gate on Linux after its build.

## What was measured

- ESP QEMU `esp_develop_9.0.0_20240606` (ESP-IDF v5.4.2's pin) finds no PSRAM: abort at
  `quad_psram: PSRAM ID read error`. `esp_develop_9.2.2_20250817` (ESP-IDF v5.5.4's pin) with
  `-m 8M` finds the 8 MB quad PSRAM of the real CoreS3 config.
- ESP-IDF v5.4.2's `idf.py qemu` passes the eFuse drive to `nvram.esp32c3.efuse`, which QEMU 9.2.2
  rejects ("invalid class name"); the eFuse image is then ignored and boot spins after
  `eFuse: calibration efuse version does not match`. With `nvram.esp32s3.efuse` and
  `BLK_VERSION_MAJOR = 1` (byte 64 = `0x01` over IDF's esp32s3 default image, whose only other
  set byte is 37 = `0x0c`, chip revision 0.3), boot reaches `$> `.
- The console must be UART (`CONFIG_ESP_CONSOLE_UART_DEFAULT=y`,
  `CONFIG_ESP_CONSOLE_SECONDARY_NONE=y`); the rest of the CoreS3 sdkconfig list is unchanged.
- A littlefs image made with the tree's own `littlefs-python` (the R2P2-ESP32 littlefs component
  pins 0.15.0; `--fs-size=1048576 --name-max=64 --block-size=4096`) holding `/home/app.mrb`,
  written over the storage partition (`0x410000`), is loaded by `main_task.rb`. A probe printing a
  marker prints it; a probe with `x = /a/` prints `uninitialized constant Regexp (NameError)`.

## Pieces (stackchan-picoruby)

| piece | holds |
|---|---|
| `lib/qemu_gate.rb` | pinned QEMU per host platform (version, URL, sha256), eFuse bytes, QEMU argv, probe source builder, verdict |
| `build_config/qemu_console.sdkconfig` | the UART console fragment |
| `Rakefile` | `qemu:setup`, `r2p2:qemu_check`; `r2p2:build_flash` = build → qemu_check → flash |
| `test-host/qemu_gate_test.rb` | pins, eFuse bytes, argv, probe source, verdict |
| `.github/workflows/firmware.yml` | `qemu:setup` + `r2p2:qemu_check` after the build |

QEMU pins (ESP-IDF v5.5.4 `tools.json`, `esp_develop_9.2.2_20250817`):

| platform | sha256 |
|---|---|
| x86_64-linux-gnu | `588bfaccd0f929650655d10a580f020c6ba9c131712d8fa519280081b8d126eb` |
| aarch64-linux-gnu | `317f6e0fd1dba0886d8110709823d909593ef29438822a14f81ebe19d72ce7cd` |
| x86_64-apple-darwin | `00b9dbc2124cf7633cb86f264fbc524226ad4001bce68bbdba43c9bdc4eb026e` |
| aarch64-apple-darwin | `aa92e337461d482f5d9f31cd8efc0bd67b3de8fcfcfb567289cb43a59c184651` |

URL: `https://github.com/espressif/qemu/releases/download/esp-develop-9.2.2-20250817/qemu-xtensa-softmmu-esp_develop_9.2.2_20250817-<platform>.tar.xz`.
`qemu:setup` downloads into `build/qemu/`, checks the sha256, extracts, and runs `--version`; a
missing shared library fails with its name and the host's package command (Linux:
`libsdl2-2.0-0 libslirp0`; macOS: `brew install libgcrypt glib pixman sdl2 libslirp`).

## `r2p2:qemu_check`

1. `idf.py -B build-qemu` in the R2P2-ESP32 tree with the Rakefile's build env,
   `-DSDKCONFIG=<abs path>/build-qemu/sdkconfig` (idf.py ignores `SDKCONFIG` in the environment and would rewrite the project `sdkconfig`; the task aborts if that file changes), and `SDKCONFIG_DEFAULTS` = the CoreS3 list with
   `sdkconfigs/usb_console` replaced by `build_config/qemu_console.sdkconfig`; `set-target esp32s3`
   on a fresh dir, then `build`. `build-qemu` is removed first (idf.py refuses to re-apply
   defaults to an existing dir).
2. Flash image: `esptool merge_bin --fill-flash-size 16MB @flash_args` from `build-qemu`, then the
   storage partition overwritten with the probe's littlefs image.
3. eFuse image: 1024 bytes, byte 37 = `0x0c`, byte 64 = `0x01`, rest zero.
4. `qemu-system-xtensa -M esp32s3 -m 8M -drive file=<flash>,if=mtd,format=raw
   -drive file=<efuse>,if=none,format=raw,id=efuse
   -global driver=nvram.esp32s3.efuse,property=drive,value=efuse
   -global driver=timer.esp32s3.timg,property=wdt_disable,value=true
   -icount shift=2,align=off,sleep=off -seed 1 -rtc clock=vm
   -display none -serial file:<log> -monitor none`, polled until a verdict is decided or 900 s of
   host time pass, then killed. `-icount` ties guest time to the instruction count, and the fixed
   seed and VM-clock RTC remove the other host inputs, so the serial output up to the shell prompt
   is a function of the image: two boots of one image give byte-identical logs up to the prompt.
   The first boot of a fresh image writes the littlefs files and takes about 200 s of host time.
5. Verdict: FAIL on `Guru Meditation`, `abort()`, `Rebooting...`, `assert failed`, or any line
   anywhere in the log matching `\((NameError|LoadError|NoMethodError|ArgumentError|TypeError|RuntimeError|Exception)\)`,
   `^Error: ` or `^Exception\(vm_id=` (gems load during VM boot, before `Loading app.mrb`, and a
   gem that fails there prints `(unknown):0: uninitialized constant Regexp (NameError)`); PASS only when the probe's marker line appears and the shell prompt follows it; FAIL on timeout. When the prompt has appeared after the marker, the verdict reads the log only up to that prompt, so output after it, which depends on when the poll lands, never changes the verdict. The log is
   kept at `/tmp/stackchan-picoruby-debug/qemu-<stamp>.log` and its path printed.

Probe (`app.mrb`, compiled with the tree's host `mrbc`), generated in this order:

1. every top-level `require` of `app/application.rb`;
2. `DEVICE_GEM_SOURCES` (the driver gems bundled into `app.mrb`);
3. the application's class bodies as the device suite extracts them (`RubyClassExtract`,
   `< BLE` excluded), so every constant a class body names at load time is resolved;
4. one wire-format round trip through `StackchanProtocol::FrameParser`;
5. `puts "QEMU_PROBE_OK"`.

QEMU does not emulate the CoreS3's I2C devices, LCD, servos, speaker or BLE radio, so the gate
covers boot, gem loading and class-body load; everything past the first hardware access stays with
`/stackchan-device-trial`.

## Placement

Branch `claude/qemu-boot-gate`, stacked on `claude/ecstatic-allen-s6qki1` (PR #11). It changes
tooling only. Each trial arm builds and flashes with the Rakefile of the commit it pins, so this
branch's `trial/lock.yml` pins its own head (PR #11's code plus the gate) for the trial arm, and
PR #11's device trial runs from this branch. `claude/stackchan-protocol-fold` merges this
branch. Merge order: PR #11, this branch, the protocol fold-in.

The base arm (`main`) builds with its own Rakefile, which has no gate; it is the known-good
firmware.
