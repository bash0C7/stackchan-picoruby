---
name: stackchan-device-iterate
description: Full dev iteration cycle — upload application, reset, capture boot log, auto-analyze panic if any (~50 s). Use for the standard "I changed application.rb, did it work?" loop.
---

# stackchan-device-iterate

## Mode

Chain.

## Action

1. Invoke `stackchan-device-upload-app` with `SRC=$SRC`.
2. Invoke `stackchan-device-reset`.
3. Invoke `stackchan-device-capture-boot` with `SECONDS=25`.
4. If panic in log → invoke `stackchan-device-crash-analyze`.
5. Report combined: upload OK, reset OK, boot markers found, panic Y/N + analysis.

## Required env

- `SRC` (optional, defaults to application.rb)

## Escalation

- Upload fail → `stackchan-device-cold-recovery`
- Persistent panic → debug session, not another iteration
