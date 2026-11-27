---
name: stackchan-device-acceptance
description: Run the pre-merge CoreS3 acceptance gate (acceptance:deploy, acceptance:app, acceptance:check, optional acceptance:darwin) pinned by acceptance/lock.yml and writing acceptance/results/<stamp>.{md,json}. Manual invocation only.
argument-hint: "[deploy|app|check|darwin] [STAMP=...]"
disable-model-invocation: true
effort: medium
---

# Pre-Merge Device Acceptance Gate

Required before merging any branch that changes firmware, gems, app, or the BLE link.
Prerequisites: CoreS3 connected on USB, Mac Bluetooth granted to `~/Applications/StackchanPico.app`, ESP-IDF available (`ESP_IDF_EXPORT` if not `~/esp/esp-idf/export.sh`), no serial monitor open.

## Step-by-Step Procedure

1. **Check board & lock**: run `bundle exec rake r2p2:boards` and verify the CoreS3 serial is present and unlocked.
2. **`acceptance:deploy`** (firmware write — run ONCE per report when the pinned firmware is not yet on the board):
   Delegate to a **haiku subagent (foreground)** so main context stays clean and `device_guard.sh` allows it:
   ```sh
   mkdir -p /tmp/stackchan-picoruby-debug
   bundle exec rake acceptance:deploy 2>&1 | tee /tmp/stackchan-picoruby-debug/acceptance-deploy.log; echo "rake exit=${PIPESTATUS[0]}"
   ```
   Require the subagent to report `rake exit` and the `[acceptance] verdict:` line verbatim. This pins every tree, runs `r2p2:setup` and `r2p2:build_flash` (behind `r2p2:qemu_check`), sends the app, verifies flash identity, and boots.
3. **`acceptance:app`** (when only the app changed — never touches firmware):
   Delegate to a **haiku subagent (foreground)**:
   ```sh
   mkdir -p /tmp/stackchan-picoruby-debug
   bundle exec rake acceptance:app 2>&1 | tee /tmp/stackchan-picoruby-debug/acceptance-app.log; echo "rake exit=${PIPESTATUS[0]}"
   ```
   Checks pins, boots under QEMU, and only on PASS uploads and resets. Follow with `acceptance:check`.
4. **`acceptance:check`** (read-only verification from Mac; never writes flash):
   Run once start to finish by the owner in a TTY terminal at the robot (or in a tmux session driven by Claude with the owner answering in chat), because head touch and physical observations (servo movement, subtitle integrity, audio gaps/distortion) require a person.
   - Untouched head within 30 s is recorded as not touched and does not block `pass`.
   - Stops before touching the board if `acceptance/lock.yml` firmware pins, firmware inputs, or app inputs diverge from what the board runs.
   - `chat` runs last and requires a live reply from `pc/sidecar`.
5. **`acceptance:darwin`** (optional — not required for merge verdict):
   Read `references/apple-device.md` in this skill directory before running. Requires an unlocked paired iPhone and a valid signing certificate (`DEVELOPMENT_TEAM=<team>`).
6. **Commit & Verdict**: commit `acceptance/results/<stamp>.md` and `.json`. Pass `STAMP=<stamp>` to target a specific report. Merge only on `verdict: pass`.

## On Failure

The run stops at the failing step and names the tree, marker, or command:
- `pins hold ...`: a checkout moved. Fix the checkout; do not edit `acceptance/lock.yml` to match drift.
- `flash identity` / `boot`: board is running different firmware or faulted. Analyze the named boot log with `stackchan-device-diagnose` (`crash-analyze`), then reproduce under `r2p2:qemu_check` or host tests before touching the robot again.
- Fix firmware/app faults off the robot. Whether and when a fix goes onto the robot is the owner's decision.
