---
name: stackchan-device-setup
description: Full R2P2-ESP32 host build + esp32s3 target setup (~10-20 min). First checkout, target switch, or when build_flash fails on picogem_init.c / gem layout drift.
---

Run in a haiku subagent (foreground, 1200000ms timeout):

    bundle exec rake r2p2:setup 2>&1 | tee /tmp/stackchan-picoruby-debug/setup.log

Exit 0 = done; follow with `stackchan-device-build-flash`. Failures are environment issues (esp-idf export, host picoruby build): report the failing component from the tail.
