# QEMU boot gate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every flash of the robot is preceded by a deterministic QEMU boot of the same tree that loads what the robot app loads.

**Architecture:** Pure logic in `lib/qemu_gate.rb` (pins, eFuse bytes, argv, probe source, verdict) with CRuby host tests; rake tasks run it against the R2P2-ESP32 tree; `r2p2:build_flash` chains it; CI runs it.

**Tech Stack:** Ruby 3.3 rake, ESP-IDF v5.4.2, ESP QEMU `esp_develop_9.2.2_20250817`, littlefs-python 0.15.0, esptool.

**Spec:** `docs/superpowers/specs/2026-09-27-qemu-boot-gate-design.md`

**Branch:** `claude/qemu-boot-gate`, stacked on `claude/ecstatic-allen-s6qki1` (PR bash0C7/stackchan-picoruby#11).

## Global Constraints

- Env: `export PATH=/opt/rbenv/versions/3.3.6/bin:$PATH LANG=C.UTF-8 SCSERVO_RB=/home/user/picoruby-scservo/mrblib/scservo.rb`; ESP-IDF: `IDF_TOOLS_PATH=/opt/esp/tools IDF_PYTHON_CHECK_CONSTRAINTS=no IDF_COMPONENT_MANAGER=0 ESP_IDF_EXPORT=/opt/esp/esp-idf/export.sh` (export `IDF_TOOLS_PATH` before sourcing `export.sh`).
- Every value in the spec's "What was measured", QEMU pin table, argv and verdict is used verbatim.
- CLAUDE.md: no comments except toolchain annotations; no history wording; host-only tools are CRuby test-unit in `test-host/`.
- Nothing writes tracked files in the R2P2-ESP32 tree; `build-qemu` is untracked build output.
- Long builds run in a haiku subagent in the foreground with `set -o pipefail`, the rake's own exit code reported, logs under `/tmp/stackchan-picoruby-debug/`.
- Merge only after PR #11's device trial passes (run from this branch).

## Review Focus

1. Determinism: no sleep used as synchronisation where a state can be polled; the only wait is the bounded poll of the boot log.
2. The gate FAILs on the protocol fold-in's `Regexp` tree and PASSes on its fix.
3. `r2p2:build_flash` cannot flash after a FAIL.

---

### Task 1: `lib/qemu_gate.rb` and its host test

**Files:** Create `lib/qemu_gate.rb`, `test-host/qemu_gate_test.rb`, `build_config/qemu_console.sdkconfig`.

- [ ] Step 1: tests first — pins per platform (version, URL, sha256 from the spec table), host platform detection (`x86_64-linux`, `aarch64-linux`, `x86_64-darwin`, `arm64-darwin`) with an error naming the platform otherwise; eFuse image (1024 bytes, byte 37 `0x0c`, byte 64 `0x01`, rest zero); argv exactly as the spec; SDKCONFIG_DEFAULTS rewrite (only `sdkconfigs/usb_console` replaced); verdict cases (marker → PASS; each failure pattern → FAIL naming the line; error class line after `Loading app.mrb` → FAIL; empty/timeout → FAIL; marker plus a later panic → FAIL).
- [ ] Step 2: probe source builder from (application path, device gem sources) in the spec's order; test it on a small fixture application (requires, a class body, a `< BLE` class that is excluded) and on the real `app/application.rb` (the source compiles with the host picotest VM's `mrbc`).
- [ ] Step 3: implement; `bundle exec rake test:host` green; commit.

### Task 2: rake tasks, run for real

**Files:** Modify `Rakefile`.

- [ ] Step 1: `qemu:setup` (download to `build/qemu/`, sha256, extract, `--version`, missing-library message) and `r2p2:qemu_check` (spec steps 1–5, using `lib/qemu_gate.rb`); `r2p2:build_flash` runs `r2p2:build`'s work, then `r2p2:qemu_check`, then the flash, and flashes nothing after a FAIL.
- [ ] Step 2: run `qemu:setup` and `r2p2:qemu_check` on this branch's tree (haiku runner): PASS, log path, time taken.
- [ ] Step 3: commit; push.

### Task 3: Trial, CI, docs

**Files:** `.github/workflows/firmware.yml`, `CLAUDE.md` (ビルド・deploy), `.claude/skills/stackchan-device-build-flash/SKILL.md`, `.claude/skills/stackchan-device-trial/SKILL.md`, `README.md` if it lists rake tasks, `HANDOFF.md` (Branches in flight row).

- [ ] Step 1: firmware.yml runs `qemu:setup` + `r2p2:qemu_check` after the build (the job's container is Linux; install `libsdl2-2.0-0 libslirp0` if missing); docs say the gate exists, what it covers and what it does not.
- [ ] Step 2: `test:host` green; `trial/lock.yml` unchanged (the trial arm's `r2p2:build_flash` now includes the gate); commit; push.

### Task 4: The gate on the protocol fold-in

**Branch:** `claude/stackchan-protocol-fold` merges `claude/qemu-boot-gate`.

- [ ] Step 1: merge; suites green.
- [ ] Step 2: `r2p2:qemu_check` on the fold-in tree at the `Regexp` commit (stackchan-picoruby `4aec1d0` code with R2P2-ESP32 `f0a8225`) → FAIL naming `uninitialized constant Regexp`; at the fix (`1244a5c` code, R2P2-ESP32 `9652d89`) → PASS. Record both log paths.
- [ ] Step 3: lock pins the new head; trial dry run; push.
