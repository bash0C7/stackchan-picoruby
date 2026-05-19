---
name: stackchan-device-capture-boot
description: Run bin/capture-with-pty for a fixed duration (default 25 s) to capture device serial output to /tmp/stackchan-picoruby-debug/boot.log. Main-context, not subagent — we need the raw log content for downstream analysis (Guru Meditation detection, panic dump extraction).
---

# stackchan-device-capture-boot

## Mode

Main context (NOT subagent).

Rationale: the captured log is consumed by `crash-analyze` or visual
inspection. Subagent summarization would lose panic dump details.

## Action

From main, run:

```bash
mkdir -p /tmp/stackchan-picoruby-debug
SECONDS=${SECONDS:-25}
LOG=${LOG:-/tmp/stackchan-picoruby-debug/boot.log}
bin/capture-with-pty $SECONDS $LOG bundle exec rake r2p2:monitor
```

(`bin/capture-with-pty` uses expect to attach a pseudo-TTY, capture output
for $SECONDS, then send Ctrl-] to detach the monitor.)

NEVER raw `cat /dev/cu.usbmodem*` — the USB CDC port re-enumerates on
reset, breaking the cat, and you'll spend two turns re-trying captures
that never see the cold-boot output. `bin/capture-with-pty` uses
`idf.py monitor` which handles renum gracefully.

## Required / optional env

- `SECONDS` — capture duration (default 25)
- `LOG` — output path (default `/tmp/stackchan-picoruby-debug/boot.log`)

## Pass / fail signal

- File exists at `$LOG` and is non-empty → capture OK. Inspect for
  `Loading app.rb`, `[application] LCD + LED cold-boot done`,
  `Guru Meditation Error`, `Rebooting...`.
- If the rake task itself aborts with `[monitor guard] idf_monitor.py is
  running` — another `rake r2p2:monitor` is already attached. Either
  detach it (Ctrl+]) or kill the conflicting pid before retrying.

## Escalation

If panic dump present (`Guru Meditation Error`), invoke
`stackchan-device-crash-analyze` with `LOG=$LOG`.
