---
name: stackchan-device-app
description: Deploy, iterate, recover, reset, wipe, or smoke-test the CoreS3 robot app (apps/robot/app.rb or robot engine gem) via PicoModem/BLE. Use when pushing app.mrb changes, recovering autostart, or verifying BLE/face behavior on hardware.
argument-hint: "[iterate|deploy|upload|cold-recovery|reset|wipe|ble-smoke|face-verify] [SRC=apps/robot/app.rb] [FACE=joy]"
context: fork
model: haiku
effort: low
allowed-tools:
  - Bash
  - Read
---

# CoreS3 Robot App Workflow

Execute the requested sub-workflow from `$ARGUMENTS` (default: `iterate`, default `SRC=apps/robot/app.rb`).
Run `mkdir -p /tmp/stackchan-picoruby-debug` first and set `set -o pipefail` in every command piped to `tee` so `rake`'s real exit code is preserved.

## Sub-workflows

### `iterate` (default: upload → reset → boot capture → reset → panic check)
1. Upload autostart payload:
   ```sh
   set -o pipefail
   bundle exec rake r2p2:upload_appmrb SRC=${SRC:-apps/robot/app.rb} 2>&1 | tee /tmp/stackchan-picoruby-debug/upload-app.log
   ```
2. Reset and wait for cold-boot + BLE advertising:
   ```sh
   set -o pipefail
   bundle exec rake r2p2:reset 2>&1 | tee /tmp/stackchan-picoruby-debug/reset.log && sleep 15
   ```
3. Capture boot log via PTY (never raw `cat /dev/cu.usbmodem*`):
   ```sh
   bin/capture-with-pty ${SECONDS:-25} /tmp/stackchan-picoruby-debug/boot.log bundle exec rake r2p2:monitor
   ```
4. Reset again (closing capture leaves the chip in ROM download mode, not advertising):
   ```sh
   set -o pipefail
   bundle exec rake r2p2:reset 2>&1 | tee /tmp/stackchan-picoruby-debug/reset-post.log && sleep 15
   ```
5. Read `/tmp/stackchan-picoruby-debug/boot.log` and check for `[application] LCD cold-boot done (torque-OFF idle)`, `HCI WORKING — advertising`, `Guru Meditation Error`, `LoadError`, `NameError`, `Rebooting...`.

### `deploy` (upload → reset)
Run steps 1 and 2 of `iterate`.

### `upload` (single PicoModem upload)
- Autostart payload (`/home/app.mrb`): step 1 of `iterate`.
- Non-autostart helper (`DST=` set):
  ```sh
  set -o pipefail
  bundle exec rake r2p2:upload_mrb SRC=${SRC} DST=${DST} 2>&1 | tee /tmp/stackchan-picoruby-debug/upload-helper.log
  ```
  `upload_mrb` cannot wipe storage without destroying `/home/app.mrb`; on a board running autostart, run `wipe` → helper `upload` → autostart `upload` → `reset`.

### `cold-recovery` (wipe → upload → reset)
Run `wipe`, then steps 1 and 2 of `iterate`. If still failing after two rounds, report that `/stackchan-device-firmware` (`full-rebuild`) is needed instead of looping.

### `wipe`
```sh
set -o pipefail
bundle exec rake r2p2:wipe_storage 2>&1 | tee /tmp/stackchan-picoruby-debug/wipe.log
```
Pass marker: `Erase operation completed successfully`. No settle sleep required before upload.

### `reset`
Run step 2 of `iterate`.

### `ble-smoke`
Never run a serial monitor concurrently (opening the port resets the board).
```sh
set -o pipefail
FACE=${FACE:-joy} COLOR=${COLOR:-} MODE=${MODE:-} SIDE=${SIDE:-} bundle exec rake r2p2:ble_control_smoke 2>&1 | tee /tmp/stackchan-picoruby-debug/ble-smoke-${FACE:-joy}.log
```
Pass marker: `[smoke] PASS` (report line verbatim).

### `face-verify`
```sh
set -o pipefail
FACE=${FACE:-joy} bundle exec rake r2p2:face_verify 2>&1 | tee /tmp/stackchan-picoruby-debug/face-verify-${FACE:-joy}.log
```
Pass marker: both `[face_verify]` PASS lines verbatim (host golden + device BLE leg).

## On Failure

Read `references/troubleshooting.md` in this skill directory to classify error signatures before reporting. Do not edit source code or retry blindly on a repeating panic.

## Output Format

Return a concise summary with:
- Sub-workflow run and exact `rake` exit code per step
- Observed pass/fail markers (verbatim)
- Log file paths written under `/tmp/stackchan-picoruby-debug/`
- If a panic appeared, note `/tmp/stackchan-picoruby-debug/boot.log` needs `stackchan-device-diagnose` (`crash-analyze`)
