---
name: stackchan-device-full-rebuild
description: Heaviest recovery — `r2p2:full_rebuild` chains build_flash → wipe_storage → upload_appmrb → reset (~7 min). Use when firmware-side code changed or cold-recovery keeps failing.
---

Run in a haiku subagent (foreground, 600000ms timeout), reporting exit code and the last 30 lines:

    bundle exec rake r2p2:full_rebuild SRC=app/application.rb 2>&1 | tee /tmp/stackchan-picoruby-debug/full-rebuild.log

- `[r2p2:full_rebuild] PASS` = done.
- No `Hash of data verified` = flash failed; see `stackchan-device-build-flash`.
- `/home/app.mrb started but never returned` = upload failed; run `stackchan-device-wipe` then retry.
- USB / esptool / port errors need a human USB replug.
