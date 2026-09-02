---
name: stackchan-device-deploy-app
description: Upload application.rb as the autostart payload and reset (~20 s). Use when application.rb changed and the device should run it.
---

1. `stackchan-device-upload-app` with `SRC=app/application.rb` (or the given SRC)
2. `stackchan-device-reset`

Upload reporting `/home/app.mrb started but never returned` → `stackchan-device-cold-recovery`.
