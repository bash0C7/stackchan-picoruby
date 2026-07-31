---
name: stackchan-device-full-rebuild
description: Heaviest recovery — chained rake task `r2p2:full_rebuild` runs build_flash → wipe_storage → upload_appmrb → reset in one invocation (~7 min). Use when mrbgem layout / sdkconfig / driver code changed, OR when cold-recovery fails repeatedly.
---

# stackchan-device-full-rebuild

## Mode

Subagent (haiku), foreground, 600000ms (10 min) timeout.

Rationale: single rake invocation chains all four phases serially with
USB-renum sleeps between them. Subagent dispatch keeps the verbose
esptool / make / picomodem logs out of main context — only pass/fail
returns.

## Action

Dispatch a general-purpose haiku subagent with this prompt:

> Run `bundle exec rake r2p2:full_rebuild SRC=$SRC` in the foreground
> with a 600000ms timeout from the repo root. Tee stdout+stderr into
> `/tmp/stackchan-picoruby-debug/full-rebuild.log`. Do not modify any
> code. Report exit code and the final 30 lines of output. Under 200
> words.

## Required env

- `SRC` — path to application Ruby file (e.g. `app/application.rb`).

## Pass / fail signal

- Exit 0 + `[r2p2:full_rebuild] PASS — firmware rebuilt + ... deployed` → success.
- `[monitor guard] idf_monitor.py is running` → human has `rake r2p2:monitor` open; ask them to Ctrl+] and retry.
- `Hash of data verified` missing from tail → flash phase failed; escalate to `stackchan-device-setup`.
- `/home/app.mrb started but never returned` → upload phase failed because the payload already on the device autostarts and never returns; escalate to wipe-then-retry.

## Escalation

- Build / link error: run `stackchan-device-setup` (full host picoruby
  rebuild regenerates `picogem_init.c`) then retry.
- USB / esptool / port permission: human USB replug, then retry.
