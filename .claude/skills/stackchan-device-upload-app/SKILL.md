---
name: stackchan-device-upload-app
description: host-compile SRC=path/to/app.rb to .mrb and upload as /home/app.mrb autostart payload via PicoModem (~7 s). Used internally by deploy-app / cold-recovery / full-rebuild / iterate chain skills. No slash alias.
---

# stackchan-device-upload-app

## Mode

Subagent (haiku), 120000ms timeout.

## Action

Dispatch:

> Run `bundle exec rake r2p2:upload_appmrb SRC=$SRC` in the foreground with a 120000ms timeout from the repo root. Tee stdout+stderr into `/tmp/stackchan-picoruby-debug/upload-app.log`. SRC is the path to the application Ruby file relative to repo root. Do not modify any code. Report exit code, the picorbc compiled size line, and any FILE_ACK / DONE_ACK lines. Under 150 words.

The task resets the board itself and waits for the shell banner, so it needs
no settle time before it and no human USB replug.

## Required env

- `SRC` — path to application .rb file (e.g. `app/application.rb`).

## Pass / fail signal

- Exit 0 + `DONE_ACK ok` → success.
- `/home/app.mrb started but never returned` → the app already on the device
  autostarts and never hands control back, so there is no shell to talk to.
  Wipe first. Not a transient failure; retrying is pointless.
- `does not exist` / `did not come back within` → the board is not enumerated
  on USB. Needs a human to replug; nothing else will help.
- `no shell banner and no boot log` → enumerated but silent. Cable or power.
- `shell did not ACK Ctrl-B` / `FILE_ACK did not arrive` → the shell was up but
  the session did not start. The task already retried; report the whole log.
- `picorbc compilation failed` → script syntax error; fix application.rb.
- `[monitor guard] idf_monitor.py is running` → human has `rake r2p2:monitor` open; Ctrl+] then retry.

## Escalation

`/home/app.mrb started but never returned` → `stackchan-device-cold-recovery`
(full wipe + retry).
