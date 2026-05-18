---
name: stackchan-device-full-rebuild
description: Heaviest recovery — build_flash firmware, wipe storage, upload application, reset (~5-10 min). Use when mrbgem layout / sdkconfig / driver code changed, OR when cold-recovery fails repeatedly.
---

# stackchan-device-full-rebuild

## Mode

Chain.

## Action

1. Invoke `stackchan-device-build-flash`.
2. Invoke `stackchan-device-wipe`.
3. Invoke `stackchan-device-upload-app` with `SRC=$SRC`.
4. Invoke `stackchan-device-reset`.
5. Report final status.

## Required env

- `SRC` (optional, defaults to application.rb)

## Escalation

If build_flash itself fails, run `stackchan-device-setup` first then retry.
