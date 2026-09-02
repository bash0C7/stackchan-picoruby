---
name: stackchan-device-wipe
description: Erase the storage partition via esptool (~7 s) so /home/app.mrb is gone. Use when autostart loops, an upload reports that app.mrb never returned, or the shell is unreachable.
---

Run in a haiku subagent (60000ms timeout):

    bundle exec rake r2p2:wipe_storage 2>&1 | tee /tmp/stackchan-picoruby-debug/wipe.log

`Erase operation completed successfully` = cleared. No settle sleep needed; the next upload resets the board itself. If the erase fails the board is off USB or in download mode: ask for a replug.
