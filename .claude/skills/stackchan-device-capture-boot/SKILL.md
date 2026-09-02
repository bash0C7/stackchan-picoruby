---
name: stackchan-device-capture-boot
description: Capture device serial output for a fixed duration (default 25 s) to /tmp/stackchan-picoruby-debug/boot.log. Runs in main context because the raw log is needed for crash analysis.
---

    mkdir -p /tmp/stackchan-picoruby-debug
    bin/capture-with-pty ${SECONDS:-25} ${LOG:-/tmp/stackchan-picoruby-debug/boot.log} bundle exec rake r2p2:monitor

Never raw `cat /dev/cu.usbmodem*`: the CDC port re-enumerates on reset and the cat goes silent. `capture-with-pty` runs idf_monitor under expect, which survives it.

Look for `[application] LCD + LED cold-boot done`, `HCI WORKING — advertising`, `Guru Meditation Error`, `Rebooting...`. A panic goes to `stackchan-device-crash-analyze`. `[monitor guard]` means another monitor is attached; detach it first.
