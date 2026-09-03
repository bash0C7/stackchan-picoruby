---
name: stackchan-device-crash-analyze
description: Resolve Guru Meditation Error PC / backtrace addresses from a boot log (LOG=, default /tmp/stackchan-picoruby-debug/boot.log) to symbols with xtensa-esp32s3-elf-addr2line.
---

Run in a haiku subagent (60000ms timeout): read `$LOG`, extract PC, EXCVADDR, and Backtrace addresses (also try each with bit 31 cleared: `0x82xxxxxx` → `0x42xxxxxx`), then

    source ~/esp/esp-idf/export.sh && xtensa-esp32s3-elf-addr2line -pfiaC -e vendor/R2P2-ESP32/build/R2P2-ESP32.elf <addresses>

Write the result to `/tmp/stackchan-picoruby-debug/crash-analyze.log` and report each resolved frame tagged mruby / NimBLE / esp-idf / FreeRTOS / app. No panic in the log is a valid result: say so.
