---
name: stackchan-device-boot-verify
description: Reset, capture the boot log, and analyze any panic. Use to confirm cold-boot completes after a deploy.
---

1. `stackchan-device-reset`
2. `stackchan-device-capture-boot` with `SECONDS=25`
3. `Guru Meditation Error` in the log → `stackchan-device-crash-analyze`; otherwise report whether `[application] LCD + LED cold-boot done` and `HCI WORKING — advertising` appeared.

Neither marker nor a panic means the capture was too short or the device hung; retry with a longer `SECONDS`.
