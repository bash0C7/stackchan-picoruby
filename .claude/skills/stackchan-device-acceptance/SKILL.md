---
name: stackchan-device-acceptance
description: Put the one firmware pinned in acceptance/lock.yml on the robot once (acceptance:deploy), send the app separately (acceptance:app, any number of times, each behind a QEMU gate), and check the board from the Mac without writing flash (acceptance:check, run once start to finish by the owner in a TTY terminal), writing acceptance/results/<stamp>.{md,json}. Required before merging anything that changes firmware, gems, app or the BLE link.
---

Needs the CoreS3 on USB, the Mac's Bluetooth granted to `~/Applications/StackchanPico.app`, and ESP-IDF (`ESP_IDF_EXPORT` if not at `~/esp/esp-idf/export.sh`). Everything runs from this checkout. The board is the one `bundle exec rake r2p2:boards` marks CoreS3, and each serial step waits on the shared esp32 lock. Nothing else may hold the serial port.

Run `acceptance:deploy` and `acceptance:app` in a haiku subagent (foreground). Tell it to report the exit status of `rake` itself and the `[acceptance] verdict:` line:

    bundle exec rake acceptance:<task> 2>&1 | tee /tmp/stackchan-picoruby-debug/acceptance-<task>.log; echo "rake exit=${PIPESTATUS[0]}"

1. `bundle exec rake r2p2:boards`: the CoreS3 is on USB and the lock is free.
2. `acceptance:deploy` (3600000 ms), only for a report that has no firmware on the board yet. It pins every tree, runs `r2p2:setup` and `r2p2:build_flash` (QEMU gate first), sends the app, reads the flash identity and boots. This is the only firmware write of the report.
3. `acceptance:check`: the owner runs it once, start to finish, in a terminal with a TTY (Terminal.app) at the robot, because the head touch and the questions (servo moved, subtitle intact, audio without gaps, audio without distortion, remote moved) need a person; a head nobody touches within 30 s is recorded as not touched and neither stops the run nor blocks `pass`. A TTY can also be a tmux session that Claude drives, with the owner answering in chat. It stops before touching anything if the `firmware:` pins of `acceptance/lock.yml`, the firmware inputs or the app inputs differ from what the board runs, and it never writes flash. `chat` runs last and needs a reply from the real sidecar.
4. The app changed: `acceptance:app` checks the pins, boots the app under QEMU, and only on a PASS sends it and boots the board again. It never touches the firmware. Then `acceptance:check` again.
5. Optional, with a paired iPhone that is unlocked (a locked phone refuses the launch: `the device was not, or could not be, unlocked`) and a valid signing certificate: `DEVELOPMENT_TEAM=<team> bundle exec rake acceptance:darwin` builds both Apple apps for the device, runs the iPhone batch and hands the robot Mac → iPhone → Mac. The Apple Watch app is built but never run (a watch nobody has woken does not run an app in the foreground). The verdict does not need it.
6. Commit `acceptance/results/<stamp>.md` and `.json`. Merge only on `verdict: pass`.

`STAMP=` picks a report other than the most recent.

When a step FAILs, the run stops. Its detail names the tree, marker or command.

- `pins hold ...`: something moved a checkout. Fix the tree; do not edit the lock to match it.
- `flash identity` / `boot`: the board is not running the deployed firmware, or it faulted. Read the boot log it names with `stackchan-device-crash-analyze`, then reproduce under QEMU (`r2p2:qemu_check`) or on the host before anything touches the robot again. Do not deploy again to find out.
- Firmware or app faults are fixed off the robot. Whether a fix goes onto the robot, and when, is the owner's call.
