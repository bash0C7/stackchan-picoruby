---
name: stackchan-device-build-flash
description: Build R2P2-ESP32 firmware and flash CoreS3 in one step (~5-10 min). Use when mrbgem layout, sdkconfig, picogem_init.c, or any firmware-side code changed. Always runs in a haiku subagent with a 600000ms timeout to keep verbose make logs out of main context.
---

# stackchan-device-build-flash

## Mode

Subagent (haiku), foreground, 600000ms (10 min) timeout.

Rationale: rake-compiler make logs and Test::Unit dot progress are extremely
verbose and would dilute main context. Subagent returns only pass/fail + the
final ~30 lines.

## Action

Dispatch a general-purpose haiku subagent with this prompt:

> Run `bundle exec rake r2p2:build_flash` in the foreground with a 600000ms timeout. Do not modify any code. Report exit code and the final 30 lines of output. Under 200 words.

## Pass / fail signal

- Exit 0 + `Hash of data verified` line in tail → success.
- Exit non-zero or `IRAM segment overflowed` / `link failed` / `picogem regen mismatch` → failure.

## Escalation

If FAIL with link error or symbol-missing, the mrbgem layout changed without
`picogem_init.c` regen. Run `stackchan-device-setup` instead (full host
picoruby rebuild + setup).
