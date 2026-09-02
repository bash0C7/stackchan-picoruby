---
name: stackchan-device-ble-smoke
description: Deploy application.rb, then send one face + LED frame over BLE from the Mac and assert the ACK (~20-40 s). FACE=, COLOR=, MODE=, SIDE= env.
---

Run in a haiku subagent (300000ms timeout), reporting the `[smoke]` line verbatim:

    FACE=$FACE COLOR=$COLOR MODE=$MODE SIDE=$SIDE bundle exec rake r2p2:ble_control_smoke 2>&1 | tee /tmp/stackchan-picoruby-debug/ble-smoke-$FACE.log

`[smoke] PASS` = ACK received. A non-zero exit is a connect / discovery / write / ACK failure. Never run a serial monitor at the same time; opening the port resets the device.
