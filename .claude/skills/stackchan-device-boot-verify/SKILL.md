---
name: stackchan-device-boot-verify
description: Reset, capture the boot log, and analyze any panic. Use to confirm cold-boot completes after a deploy.
---

1. `stackchan-device-reset`
2. `stackchan-device-capture-boot` with `SECONDS=25`
3. `stackchan-device-reset`: closing the capture leaves the chip in ROM download mode (enumerated on USB, not advertising), so reset before anything uses BLE.
4. `Guru Meditation Error` in the log → `stackchan-device-crash-analyze`; otherwise report whether `[application] LCD cold-boot done (torque-OFF idle)` and `HCI WORKING — advertising` appeared.

Neither marker nor a panic means the capture was too short or the device hung; retry with a longer `SECONDS`.
