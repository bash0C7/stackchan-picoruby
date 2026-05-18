---
name: stackchan-device-ble-smoke
description: Send a single BLE NUS combo frame (face + LED) to the device and assert ACK via Mac CoreBluetooth (~20-40 s). Claude-driven HITL step, no human slash alias.
---

# stackchan-device-ble-smoke

## Mode

Subagent (haiku), 300000ms timeout.

## Action

Dispatch:

> Run `FACE=$FACE COLOR=$COLOR MODE=$MODE SIDE=$SIDE bundle exec rake r2p2:ble_control_smoke` foreground with 300000ms timeout. Do not modify code. Report exit code and any `[smoke] PASS` / `[smoke] FAIL` line verbatim. Under 150 words.

## Required env

- `FACE` (neutral/smile/joy/surprised/sad/angry)
- `COLOR` (e.g. red, blue, white)
- `MODE` (solid / breathing / blink)
- `SIDE` (left / right / both)

## Pass / fail signal

- `[smoke] PASS — face=<F> LED=<C> <M> (side=<S>)` → success. ACK received.
- Non-zero exit → connection / discovery / write / ACK failure. Check
  `[smoke] FAIL ...` line.

## Escalation

ACK failure usually means autostart payload mismatch (different Dispatcher
in app.mrb than the FACE_INDICES sent). Re-run with `stackchan-device-deploy-app`.
