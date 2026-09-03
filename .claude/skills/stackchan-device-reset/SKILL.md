---
name: stackchan-device-reset
description: RTS-pulse the CoreS3 and wait 15 s for cold-boot (escape hatch + init + BLE advertise). Use after an upload so the new payload takes effect.
---

Run in a haiku subagent (30000ms timeout):

    bundle exec rake r2p2:reset 2>&1 | tee /tmp/stackchan-picoruby-debug/reset.log && sleep 15

Exit 0 = reset sent. Non-zero = serial driver problem; check `ls /dev/cu.usbmodem*`. If the device stays silent afterwards, run `stackchan-device-boot-verify`.
