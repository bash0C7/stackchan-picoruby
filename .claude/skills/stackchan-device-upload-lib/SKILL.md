---
name: stackchan-device-upload-lib
description: host-compile a non-autostart .rb to .mrb and upload to DST under /home/lib/ or similar (~7 s). Used for picoruby load_path-resolvable helpers. No slash alias.
---

# stackchan-device-upload-lib

## Mode

Subagent (haiku), 120000ms timeout.

## Action

Dispatch:

> Run `bundle exec rake r2p2:upload_mrb SRC=$SRC DST=$DST` in the foreground with 120000ms timeout. Both SRC and DST are required env vars. Report exit code + DONE_ACK. Under 100 words.

## Required env

- `SRC` — path to source .rb
- `DST` — absolute device path ending in `.mrb` (e.g. `/home/lib/helper.mrb`)

## Pass / fail signal

Identical to upload-app; the only difference is DST is explicit.
