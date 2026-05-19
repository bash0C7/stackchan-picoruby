---
name: stackchan-device-reset
description: RTS-pulse the CoreS3 to hard-reset and wait 15 s for cold-boot (escape hatch + cold-boot init + sleep_ms 3000 + BLE adv). Use after upload_appmrb to bring the new payload into effect.
---

# stackchan-device-reset

## Mode

Subagent (haiku), 30000ms timeout.

## Action

Dispatch:

> Run `bundle exec rake r2p2:reset` in the foreground from the repo root, teeing stdout+stderr into `/tmp/stackchan-picoruby-debug/reset.log`, then sleep 15. Report exit code. Under 80 words.

## Pass / fail signal

- Rake exit 0 → device reset issued. Cold-boot timing is implicit (the 15s sleep covers escape hatch + init + BTstack yield + BLE adv).
- Rake exit non-zero → USB / serial driver problem. Check `ls /dev/cu.usbmodem*`.
- `[monitor guard] idf_monitor.py is running` → human has `rake r2p2:monitor` open; Ctrl+] then retry.

## Escalation

If reset succeeds but the device does not subsequently respond, run
`stackchan-device-boot-verify` to capture the boot log and check for panic.
