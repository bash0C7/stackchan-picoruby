---
name: stackchan-device-deploy-app
description: Upload application .mrb and reset the device (upload-app + reset, ~20 s). Use during dev iteration when application.rb changed and the device should adopt the new payload.
---

# stackchan-device-deploy-app

## Mode

Chain — invokes `stackchan-device-upload-app` then `stackchan-device-reset`
in sequence.

## Action

1. Invoke `stackchan-device-upload-app` with `SRC=$SRC` (default
   `app/application.rb`).
2. On success, invoke `stackchan-device-reset`.
3. Report combined status.

## Required env

- `SRC` (optional, defaults to application.rb)

## Pass / fail signal

- Upload PASS + reset PASS → deploy complete. Cold-boot should begin.
- Upload `FILE_ACK got nil` → escalate to `stackchan-device-cold-recovery`.
