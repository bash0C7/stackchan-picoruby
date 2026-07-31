---
name: stackchan-device-wipe
description: Erase the storage partition (0x410000-0x510000, 1 MB) via esptool + hard-reset (~7 s). Use when app.mrb autostart loops, an upload reports that /home/app.mrb never returned, or the shell is unreachable.
---

# stackchan-device-wipe

## Mode

Subagent (haiku), 60000ms timeout.

## Action

Dispatch:

> Run `bundle exec rake r2p2:wipe_storage` in the foreground with 60000ms timeout from the repo root, teeing stdout+stderr into `/tmp/stackchan-picoruby-debug/wipe.log`. Report exit code. Under 80 words.

No settle sleep afterwards: the upload task resets the board and waits for the
shell banner on its own.

## Pass / fail signal

- Exit 0 + `Erase operation completed successfully` → storage cleared.
- Exit non-zero → USB driver / esptool / port permission issue. Manual intervention.
- `[monitor guard] idf_monitor.py is running` → human has `rake r2p2:monitor` open; Ctrl+] then retry.

## Escalation

If wipe itself fails, USB device may be gone or in download mode. Ask the
human to USB-replug. If wipe works but subsequent upload still hangs, run
`stackchan-device-full-rebuild`.
