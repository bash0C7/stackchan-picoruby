---
name: stackchan-device-diagnose
description: Inspect CoreS3 USB/flash identity, capture cold-boot serial logs via PTY, verify boot markers, or resolve Guru Meditation Error PC/backtrace addresses with addr2line. Use when debugging boot failures, panics, silent devices, or firmware mismatch.
argument-hint: "[boot-verify|capture|crash-analyze|identity] [SECONDS=25] [LOG=/tmp/stackchan-picoruby-debug/boot.log]"
context: fork
model: sonnet
effort: medium
allowed-tools:
  - Bash
  - Read
  - Grep
---

# CoreS3 Diagnostics & Crash Analysis

Execute the requested mode from `$ARGUMENTS` (default: `boot-verify`).
Run `mkdir -p /tmp/stackchan-picoruby-debug` first and use `set -o pipefail` on every pipeline.

## Modes

### `identity` (read-only board & flash check)
```sh
bundle exec rake r2p2:boards
bundle exec rake r2p2:flash_identity
```
Verify storage offset (`0x410000`) and `App version` against the current tree. If from a different tree, report that `/stackchan-device-firmware` (`full-rebuild`) is needed.

### `capture` (serial boot log capture)
Never run raw `cat /dev/cu.usbmodem*`; USB CDC re-enumerates on reset and `cat` goes silent.
```sh
bin/capture-with-pty ${SECONDS:-25} ${LOG:-/tmp/stackchan-picoruby-debug/boot.log} bundle exec rake r2p2:monitor
```
Always follow capture with a reset so the chip is not left in ROM download mode (enumerated on USB without BLE advertising):
```sh
set -o pipefail
bundle exec rake r2p2:reset 2>&1 | tee /tmp/stackchan-picoruby-debug/reset-after-capture.log && sleep 15
```

### `boot-verify` (reset → capture → reset → marker & panic check)
1. Reset:
   ```sh
   set -o pipefail
   bundle exec rake r2p2:reset 2>&1 | tee /tmp/stackchan-picoruby-debug/reset.log && sleep 15
   ```
2. Run `capture` (includes post-capture reset).
3. Inspect the log from the first anomaly onward for:
   - Healthy markers: `[application] boot`, `[boot] step:`, `[application] LCD cold-boot done (torque-OFF idle)`, `HCI WORKING — advertising`
   - Failure markers: `LoadError`, `cannot load`, `NameError`, `Guru Meditation Error`, `stack overflow`, `Rebooting...`
   - Note: bootloader `Partition Table:` / `App version` lines may be missed depending on USB re-enumeration timing; judge boot health by application markers and faults.
4. If `Guru Meditation Error` appears, immediately run `crash-analyze` on the same log.
5. If neither healthy markers nor a fault appear, report that the capture window may be too short or the board hung, and suggest retrying with a larger `SECONDS`.

### `crash-analyze` (resolve PC / EXCVADDR / Backtrace)
1. Read `${LOG:-/tmp/stackchan-picoruby-debug/boot.log}`. If no panic is present, report that explicitly and stop.
2. Extract `PC`, `EXCVADDR`, and every `Backtrace:` address. For each `0x82xxxxxx` address, also include its bit-31-cleared twin (`0x42xxxxxx`).
3. Resolve symbols against the built ELF:
   ```sh
   source "${ESP_IDF_EXPORT:-$HOME/esp/esp-idf/export.sh}" >/dev/null
   xtensa-esp32s3-elf-addr2line -pfiaC -e vendor/R2P2-ESP32/build/R2P2-ESP32.elf <addresses> | tee /tmp/stackchan-picoruby-debug/crash-analyze.log
   ```
4. Tag each resolved frame as `mruby` / `NimBLE` / `esp-idf` / `FreeRTOS` / `app`.

## Output Format

Return:
- Exact exit codes and log paths
- Boot markers found / missing (verbatim)
- First anomaly and, if panicked, the tagged backtrace table from `/tmp/stackchan-picoruby-debug/crash-analyze.log`
- Recommended off-device reproduction path (`r2p2:qemu_check` or host test) when a fault is found
