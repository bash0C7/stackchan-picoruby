---
name: stackchan-device-face-verify
description: Two-leg face verification — host golden-SHA assert + device BLE write/ACK (~30 s total). Use after HITL approval to lock geometry against regression.
---

# stackchan-device-face-verify

## Mode

Subagent (haiku), 300000ms timeout.

## Action

Dispatch:

> Run `bundle exec rake r2p2:face_verify FACE=$FACE` foreground with 300000ms timeout from the repo root. Tee stdout+stderr into `/tmp/stackchan-picoruby-debug/face-verify-$FACE.log`. Report exit code and the two PASS lines (`[face_verify] host golden SHA PASS for face=...` and `[face_verify] PASS ...`) verbatim. Under 150 words.

## Required env

- `FACE` — name of registered face (e.g. sad, angry)

## Pass / fail signal

- Both PASS lines present and exit 0 → fully verified.
- `host golden SHA FAIL` → geometry drift on host; re-register golden if intentional.
- Host PASS but BLE leg fails → device payload mismatch; redeploy with `stackchan-device-deploy-app`.
