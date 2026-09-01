---
name: stackchan-device-face-verify
description: Verify one face both ways — host golden dump assert and device BLE write + ACK (~30 s). FACE= env.
---

Run in a haiku subagent (300000ms timeout), reporting the two `[face_verify]` PASS lines verbatim:

    FACE=$FACE bundle exec rake r2p2:face_verify 2>&1 | tee /tmp/stackchan-picoruby-debug/face-verify-$FACE.log

Host golden FAIL = geometry drift; re-register with `rake face:register_golden FACE=$FACE` only if the change is intended. Host PASS but device leg FAIL = stale payload; `stackchan-device-deploy-app`.
