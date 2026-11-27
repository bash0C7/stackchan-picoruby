---
name: stackchan-device-firmware
description: Run heavy CoreS3 firmware tasks — r2p2:setup, r2p2:build_flash (QEMU gate + clean build + flash), r2p2:full_rebuild, or r2p2:qemu_check. Manual invocation only because flashing mutates device firmware.
argument-hint: "[build-flash|full-rebuild|setup|qemu-check] [SRC=apps/robot/app.rb]"
disable-model-invocation: true
context: fork
model: haiku
effort: low
allowed-tools:
  - Bash
  - Read
  - Grep
---

# CoreS3 Firmware Build & Flash

Execute the requested operation from `$ARGUMENTS` (default: `build-flash`).
Run `mkdir -p /tmp/stackchan-picoruby-debug` first and set `set -o pipefail` so `rake`'s real exit code is preserved.

## Operations

### `build-flash` (QEMU boot gate → clean build → flash)
```sh
set -o pipefail
bundle exec rake r2p2:build_flash 2>&1 | tee /tmp/stackchan-picoruby-debug/build-flash.log
```
- Runs `r2p2:qemu_check` first; `[r2p2:qemu_check] FAIL` stops before flashing and prints `/tmp/stackchan-picoruby-debug/qemu-*.log`.
- Success: exit 0 + `Hash of data verified`. Flash erases storage, so follow with `stackchan-device-app` (`cold-recovery` or `deploy`).

### `full-rebuild` (build_flash → wipe_storage → upload_appmrb → reset)
```sh
set -o pipefail
bundle exec rake r2p2:full_rebuild SRC=${SRC:-apps/robot/app.rb} 2>&1 | tee /tmp/stackchan-picoruby-debug/full-rebuild.log
```
- Success: exit 0 + `[r2p2:full_rebuild] PASS`.

### `setup` (R2P2-ESP32 host build + esp32s3 target setup)
Use on first checkout, target switch, after adding gems to `build_config/esp32-stackchan.rb`, or when `build_flash` fails on `picogem_init.c` / gem layout drift.
```sh
set -o pipefail
bundle exec rake r2p2:setup 2>&1 | tee /tmp/stackchan-picoruby-debug/setup.log
```
- Success: exit 0; follow with `build-flash`.

### `qemu-check` (boot gate only, never touches hardware)
```sh
set -o pipefail
bundle exec rake r2p2:qemu_check 2>&1 | tee /tmp/stackchan-picoruby-debug/qemu-check.log
```

## Failure Diagnosis

- `[r2p2:qemu_check] FAIL`: read the printed `/tmp/stackchan-picoruby-debug/qemu-*.log` and report the first error (`LoadError`, `NameError`, `Guru Meditation`, stack overflow).
- `IRAM segment overflowed` / undefined symbol / link error: grep the missing symbol in the source tree; if absent it is a stale object, if gem layout changed run `setup`.
- `[monitor guard] idf_monitor.py is running`: detach open monitor (`Ctrl+]`) and retry.
- USB / esptool / port error: run `bundle exec rake r2p2:boards`; request a USB replug only if the CoreS3 serial is absent from that list.

## Output Format

Report:
- Exact `rake` exit code
- Pass/fail marker (`Hash of data verified`, `[r2p2:full_rebuild] PASS`, `[r2p2:qemu_check] FAIL`, etc.)
- Last 30 lines of the log (or the first failing error block) and the log path
