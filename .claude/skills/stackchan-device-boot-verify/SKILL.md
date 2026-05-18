---
name: stackchan-device-boot-verify
description: Reset and capture boot log; if a panic dump is detected, automatically resolve crash addresses via crash-analyze. Use to confirm cold-boot completes after deploy.
---

# stackchan-device-boot-verify

## Mode

Chain — subagent for reset, main for capture, subagent again for analyze.

## Action

1. Invoke `stackchan-device-reset`.
2. Invoke `stackchan-device-capture-boot` with `SECONDS=25 LOG=/tmp/boot.log`.
3. Inspect `/tmp/boot.log` for `Guru Meditation Error`:
   - Present → invoke `stackchan-device-crash-analyze` with `LOG=/tmp/boot.log`. Report the analysis.
   - Absent → check for `[application] LCD + LED cold-boot done` and `HCI WORKING — advertising`. Report success markers found.

## Pass / fail signal

- `[application] LCD + LED cold-boot done` + no panic → cold-boot completed.
- `Guru Meditation Error` → analysis follows.
- Neither marker nor panic → device output truncated or hung; consider increasing SECONDS.
