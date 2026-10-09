---
name: stackchan-device-deploy-app
description: Upload apps/robot/app.rb as the autostart payload and reset (~20 s). Use when the app or the robot engine gem changed and the device should run it.
---

1. `stackchan-device-upload-app` with `SRC=apps/robot/app.rb` (or the given SRC)
2. `stackchan-device-reset`

Upload reporting `/home/app.mrb started but never returned` → `stackchan-device-cold-recovery`.
