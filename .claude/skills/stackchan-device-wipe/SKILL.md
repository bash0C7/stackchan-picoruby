---
name: stackchan-device-wipe
description: Erase the storage partition (0x210000-0x310000, 1 MB) via esptool + hard-reset (~7 s). Use when app.mrb autostart loops, FILE_ACK got nil persists, or shell is unreachable.
---

# stackchan-device-wipe

## Mode

Subagent (haiku), 60000ms timeout.

## Action

Dispatch:

> Run `bundle exec rake r2p2:wipe_storage` in the foreground with 60000ms timeout, then sleep 15 to let the device settle. Report exit code. Under 80 words.

## Pass / fail signal

- Exit 0 + `Erase operation completed successfully` → storage cleared.
- Exit non-zero → USB driver / esptool / port permission issue. Manual intervention.

## Escalation

If wipe itself fails, USB device may be gone or in download mode. Ask the
human to USB-replug. If wipe works but subsequent upload still hangs, run
`stackchan-device-full-rebuild`.
