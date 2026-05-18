---
name: stackchan-device-crash-analyze
description: Parse a /tmp/boot.log (or LOG=...) for Guru Meditation Error register dumps and resolve PC / backtrace addresses to symbols via xtensa-esp32s3-elf-addr2line against the local R2P2-ESP32.elf. Subagent (haiku) summarizes addr2line output. No slash alias — claude/AI driven.
---

# stackchan-device-crash-analyze

## Mode

Subagent (haiku), 60000ms timeout.

## Action

Dispatch:

> Read $LOG (default /tmp/boot.log). Extract any `Guru Meditation Error` PC, EXCVADDR, A0/A1/.., and Backtrace addresses. For each address, also try the variant with bit 31 cleared (`0x82xxxxxx` → `0x42xxxxxx`). Run xtensa-esp32s3-elf-addr2line against /Users/bash/dev/src/github.com/bash0C7/R2P2-ESP32/build/R2P2-ESP32.elf:
>
>     source /Users/bash/dev/src/github.com/bash0C7/esp-idf/export.sh && xtensa-esp32s3-elf-addr2line -pfiaC -e .../R2P2-ESP32.elf <addresses>
>
> Categorize each resolved function (mruby / BTstack / esp-idf / FreeRTOS / app). Report under 250 words.

## Required env

- `LOG` — path to boot log (default `/tmp/boot.log`)

## Pass / fail signal

This skill always succeeds; its output is the analysis. The "failure" mode
is "no panic in log" — then the skill reports "no Guru Meditation found".
