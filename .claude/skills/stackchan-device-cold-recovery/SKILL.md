---
name: stackchan-device-cold-recovery
description: Wipe storage, upload application, reset (~30 s). Use when autostart misbehaves, an upload reports app.mrb never returned, or the LCD stays blank after a deploy.
---

1. `stackchan-device-wipe`
2. `stackchan-device-upload-app` with `SRC=app/application.rb` (or the given SRC)
3. `stackchan-device-reset`

Still failing after two rounds → `stackchan-device-full-rebuild` (the firmware itself may be stale).
