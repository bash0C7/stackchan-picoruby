---
name: stackchan-device-build-flash
description: Build R2P2-ESP32 firmware and flash CoreS3 in one step (~5-10 min). Use when mrbgems, sdkconfig, or any firmware-side code changed.
---

Run in a haiku subagent (foreground, 600000ms timeout), reporting exit code and the last 30 lines:

    bundle exec rake r2p2:build_flash 2>&1 | tee /tmp/stackchan-picoruby-debug/build-flash.log

- Exit 0 + `Hash of data verified` = flashed. The storage partition is wiped by flash, so deploy the app next (`stackchan-device-cold-recovery`).
- `IRAM segment overflowed` / link error / undefined symbol = grep the symbol in the source tree first; if absent it is a stale object, if the gem layout changed run `stackchan-device-setup`.
- `[monitor guard] idf_monitor.py is running` = a human has `rake r2p2:monitor` open; Ctrl+] then retry.
