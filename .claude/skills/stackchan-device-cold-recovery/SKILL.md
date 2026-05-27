---
name: stackchan-device-cold-recovery
description: Standard recovery when device autostart is misbehaving — wipe storage, upload application, reset (~30 s total). Use when FILE_ACK got nil persists, autostart loops, or LCD is unexpectedly blank after a deploy attempt.
---

# stackchan-device-cold-recovery

## Mode

Chain.

## Action

1. Invoke `stackchan-device-wipe` (clears /home/app.mrb).
2. Invoke `stackchan-device-upload-app` with `SRC=$SRC` (default
   `app/application.rb`).
3. Invoke `stackchan-device-reset`.
4. Report final status.

## Required env

- `SRC` (optional, defaults to application.rb)

## Escalation

If still failing after cold-recovery (2 attempts), escalate to
`stackchan-device-full-rebuild` (the firmware itself may be stale).
