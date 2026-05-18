---
name: stackchan-device-upload-app
description: host-compile SRC=path/to/app.rb to .mrb and upload as /home/app.mrb autostart payload via PicoModem (~7 s). Used internally by deploy-app / cold-recovery / full-rebuild / iterate chain skills. No slash alias.
---

# stackchan-device-upload-app

## Mode

Subagent (haiku), 120000ms timeout.

## Action

Dispatch:

> Run `bundle exec rake r2p2:upload_appmrb SRC=$SRC` in the foreground with a 120000ms timeout. SRC is the path to the application Ruby file relative to repo root. Do not modify any code. Report exit code, the picorbc compiled size line, and any FILE_ACK / DONE_ACK lines. Under 150 words.

## Required env

- `SRC` — path to application .rb file (e.g. `mrbgems/picoruby-stackchan-protocol/examples/application.rb`).

## Pass / fail signal

- Exit 0 + `DONE_ACK ok` → success.
- `FILE_ACK got nil` → device autostart loop occupies STDIN; escalate to wipe.
- `picorbc compilation failed` → script syntax error; fix application.rb.

## Escalation

`FILE_ACK got nil` → `stackchan-device-cold-recovery` (full wipe + retry).
