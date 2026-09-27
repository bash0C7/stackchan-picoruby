---
name: stackchan-device-trial
description: Put the commits pinned in trial/lock.yml on the robot (base arm, then trial arm, one session): pin R2P2-darwin and build the Mac VM + app bundle once for both arms, pin every tree, build + flash with each arm's own tooling (the trial arm's build_flash runs the QEMU boot gate first), check the boot log, drive it over BLE and dRuby, time it, and write trial/results/<stamp>.{md,json} (~45 min). Required before merging anything that changes firmware, gems, app or the BLE link.
---

Needs the CoreS3 on USB, the Mac's Bluetooth, and ESP-IDF (`ESP_IDF_EXPORT` if not at `~/esp/esp-idf/export.sh`). Nothing else may hold the serial port.

1. Run in a haiku subagent (foreground, 3600000 ms timeout). Tell it to report the exit status of `rake` itself and the `[trial] verdict:` line:

       bundle exec rake trial:run 2>&1 | tee /tmp/stackchan-picoruby-debug/trial-run.log; echo "rake exit=${PIPESTATUS[0]}"

   The subagent has no TTY, so the operator questions stay unanswered.
2. Ask the operator in the main context: `bundle exec rake trial:answer` (servo moved, subtitle intact, audio without gaps, remote moved — per arm).
3. With the trial firmware still on the robot and a paired iPhone + Apple Watch: `DEVELOPMENT_TEAM=<team> bundle exec rake trial:darwin`, then `rake trial:answer` again.
4. Commit `trial/results/<stamp>.md` and `.json`. Merge only on `verdict: pass`.

- A step marked FAIL stops the run; its detail names the tree, marker or command. `pins hold ...` = something moved a checkout (fix the tree, do not edit the lock to match it). `boot` = read the boot log it names with `stackchan-device-crash-analyze`.
- A FAIL under `pc_vm` = the Mac VM (`pc:vm_build` / `pc:app_bundle` at the locked R2P2-darwin) did not build; no arm runs.
- Change what is trialled only by editing `trial/lock.yml` (full shas).
- Timings are compared only inside one report (base vs trial of the same run).
