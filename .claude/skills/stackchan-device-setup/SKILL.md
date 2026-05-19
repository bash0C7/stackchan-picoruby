---
name: stackchan-device-setup
description: Full R2P2-ESP32 host build + target setup (~10-20 min). Use on first checkout, target switch, or when build_flash fails due to picogem_init.c / gem layout drift. Always haiku subagent with 1200000ms timeout.
---

# stackchan-device-setup

## Mode

Subagent (haiku), 1200000ms (20 min) timeout.

## Action

Dispatch:

> Run `bundle exec rake r2p2:setup` in the foreground with a 1200000ms timeout from the repo root. Tee stdout+stderr into `/tmp/stackchan-picoruby-debug/setup.log`. Do not modify any code. Report exit code and the final 30 lines. Under 200 words.

## Pass / fail signal

- Exit 0 → success. Follow up with `stackchan-device-build-flash`.
- Exit non-zero → consult R2P2-ESP32 sdkconfig / dependency state; manual intervention required.

## Escalation

Setup failures are usually environment issues (esp-idf export, swiftly env,
picoruby host build). Inspect output for the specific component that failed.
