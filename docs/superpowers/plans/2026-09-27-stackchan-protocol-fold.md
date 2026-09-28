# StackChan protocol fold-in Implementation Plan (DSL step 1 of 6)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The StackChan wire format (parse and encode) lives in one in-repo gem, `mrbgems/picoruby-stackchan-protocol`, used by the robot firmware and the Mac side; the picoruby-stackchan-protocol repo is no longer a dependency.

**Architecture:** Copy the protocol gem into stackchan-picoruby, move the shared gem's codec and text sanitiser into it, and give the firmware the gem as a gem dir through an environment list the Rakefile already passes to R2P2-ESP32. iOS/Watch keep their own codec until step 4.

**Tech Stack:** PicoRuby mrbgems, picotest on the host VM, R2P2-ESP32 build_config, ESP-IDF v5.4.

**Spec:** `.superpowers/specs/2026-09-27-stackchan-dsl-design.md` (section "stackchan-picoruby layout", "Order" step 1)

**Branch:** `claude/stackchan-protocol-fold`, stacked on `claude/ecstatic-allen-s6qki1` (PR bash0C7/stackchan-picoruby#11). It merges only after PR #11 has a passing trial report and is merged, and after its own trial passes.

## Global Constraints

- Env: `export PATH=/opt/rbenv/versions/3.3.6/bin:$PATH LANG=C.UTF-8 SCSERVO_RB=<picoruby-scservo clone>/mrblib/scservo.rb`; suites `bundle exec rake picotest:run`, `SUITE=<name> …`, `bundle exec rake test:host`.
- CLAUDE.md rules: no comments (code How, tests What, commits Why); no history wording; gem layout `mrbgem.rake` + `mrblib/<gem>.rb` + `mrblib/<gem>/*.rb` + `test/*_test.rb`; tests are picotest; no `require` of siblings inside mrblib.
- Constant names stay: `StackchanProtocol::FrameParser`, `Stackchan::BLE::FrameCodec`, `Stackchan::AI::FrameText`. Only their gem changes.
- Wire bytes unchanged: every existing codec and parser test passes unmodified except for its location.
- Firmware: `R2P2_GEM_DIRS` (colon-separated) replaces `STACKCHAN_AOT_GEMS`; it carries the AOT kernel gem, the kernel registry and the protocol gem.
- Merge only on a passing `/stackchan-device-trial` report.

## Review Focus

1. A frame with Japanese text parses on the device VM exactly as on the host (the multibyte case moves with the gem and still runs on the host VM with `MRB_UTF8_STRING`).
2. The Mac daemon starts on the Mac VM with the new load list (no constant missing at boot).
3. The firmware image contains the protocol gem from the in-repo path, not a fetched copy (`build/repos/esp32-picoruby/picoruby-stackchan-protocol` absent after a clean setup).
4. The base trial arm still builds with its own R2P2-ESP32 pin (`STACKCHAN_AOT_GEMS`), untouched by the rename.

---

### Task 1: In-repo protocol gem with picotest

**Files:**
- Create: `mrbgems/picoruby-stackchan-protocol/{mrbgem.rake,mrblib/stackchan-protocol.rb,mrblib/stackchan-protocol/frame_parser.rb,test/frame_parser_test.rb}` from picoruby-stackchan-protocol `5e92d42`
- Modify: `test/picotest/harness.rb` (new suite `stackchan-protocol`)

- [ ] Step 1: copy the mrblib and mrbgem.rake; rewrite `test/frame_parser_test.rb` as a `Picotest::Test` with the same cases and names.
- [ ] Step 2: add the suite; `SUITE=stackchan-protocol bundle exec rake picotest:run` → all 14 cases pass, including both multibyte cases.
- [ ] Step 3: commit (body names the source repo and sha).

### Task 2: Codec and text sanitiser move into the protocol gem

**Files:**
- Move: `mrbgems/picoruby-stackchan-shared/mrblib/stackchan/ble/frame_codec.rb`, `…/ai/frame_text.rb`, their rbs and tests → `mrbgems/picoruby-stackchan-protocol/`
- Modify: `pc/stackchan-pico/app/boot_daemon.rb` load list, `test/picotest/harness.rb` SHARED_MRBLIB / pc lists, shared gem README

**Interfaces:** Produces the same constants from the new path; the shared gem keeps `errors.rb` and `send_builder.rb` until step 3.

- [ ] Step 1: `git mv` the files; split the shared test so codec and text cases live in the protocol gem's tests.
- [ ] Step 2: update both load lists (boot_daemon, harness) to load protocol files before shared files.
- [ ] Step 3: all suites + test:host green; commit.

### Task 3: Device suite parses with the real FrameParser

**Files:** `test/picotest/harness.rb` (device suite loads the protocol mrblib), `test/device/audio_receiver_test.rb` (drop the hand-written parser)

- [ ] Step 1: load the protocol mrblib in the device suite; replace the test's parser with `StackchanProtocol::FrameParser.new`.
- [ ] Step 2: `SUITE=device` green; the no-speaker drain test still fails against a version of AudioReceiver that feeds the blast to the parser (check once, do not commit it). Commit.

### Task 4: Firmware takes the in-repo gem

**Files:**
- Modify: `Rakefile` (`aot_build_env` → exports `R2P2_GEM_DIRS` with the AOT gem, the registry and `mrbgems/picoruby-stackchan-protocol`)
- Modify (R2P2-ESP32 branch): `components/picoruby-esp32/build_config/xtensa-esp-picoruby.rb` — read `R2P2_GEM_DIRS`, drop the `bash0C7/picoruby-stackchan-protocol` line
- Modify: `CLAUDE.md` 構成 line naming where `StackchanProtocol::FrameParser` comes from; README

- [ ] Step 1: make the two edits; `r2p2:setup` + `r2p2:build` for the trial worktree (haiku subagent, foreground, exit code of rake itself, log under `/tmp/stackchan-picoruby-debug/`).
- [ ] Step 2: check Review Focus 3 (no fetched protocol cache after a clean setup; the gem's objects built from the in-repo path). Report the firmware image size against the previous trial arm (`0x2560b0`): the robot now also carries the encoder and `FrameText`.
- [ ] Step 3: compile the bundled app with mrbc; commit in both repos; push.

### Task 5: Trial pins

**Files:** `trial/lock.yml` (trial arm: new stackchan-picoruby and R2P2-ESP32 shas; `picoruby-stackchan-protocol` removed from the trial arm's `repos`), `HANDOFF.md` counts

- [ ] Step 1: update the lock; `bundle exec rake test:host` (device_trial tests read it) green.
- [ ] Step 2: trial-arm dry run (pin → setup → build → pins hold) as in the previous plan's Task 10; commit; push; PR body.

### After the trial passes and this merges

Archive `bash0C7/picoruby-stackchan-protocol` (the user does this; archiving changes who can push).
