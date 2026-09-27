# StackChan robot engine Implementation Plan (DSL step 2 of 6)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The robot's behaviour is one DSL file, `apps/robot/app.rb` (`StackChan.robot do |bot| … end`); everything it does not arrange (cold boot, BLE, tick loop, audio, dRuby front, built-in frame keys) is the engine in `mrbgems/picoruby-stackchan-robot`. No `$` and no top-level `@` in the app.

**Architecture:** Move the classes out of `app/application.rb` into the robot gem under `StackChan::Robot`, unchanged in behaviour. Make faces data (geometry hashes) instead of subclasses, replace the fixed face / touch tables with handler tables filled by the DSL, and move cold boot and the BLE peripheral into the engine. The gem is pure Ruby and is bundled into `app.mrb` like the other device gems, so this step flashes no new Ruby into the firmware; the firmware gains one C method, `Machine.stack_high_water_mark`, used by the trial.

**Tech Stack:** PicoRuby (mruby VM, 8 KB task stack), picotest on the host VM, R2P2-ESP32 C component, ESP QEMU gate.

**Spec:** `docs/superpowers/specs/2026-09-27-stackchan-dsl-design.md` ("Robot engine", "Execution model", "No global variables", "Order" step 2)

**Branch:** `claude/stackchan-robot-engine` (stackchan-picoruby, R2P2-ESP32), stacked on `claude/stackchan-protocol-fold` (bash0C7/stackchan-picoruby#13). Merges after #13 and after its own trial passes.

## Global Constraints

- Env: `export PATH=/opt/rbenv/versions/3.3.6/bin:$PATH LC_ALL=C.UTF-8 SCSERVO_RB=<picoruby-scservo clone>/mrblib/scservo.rb`; suites `bundle exec rake picotest:run`, `SUITE=<name> …`, `bundle exec rake test:host`.
- CLAUDE.md rules: no comments (code How, tests What, commits Why); no history wording; gem layout `mrbgem.rake` + `mrblib/<gem>.rb` + `mrblib/<gem>/*.rb` + `test/*_test.rb`; picotest; no sibling `require` inside mrblib.
- 8 KB stack: DSL blocks run once at boot. The tick path calls stored Procs with `call` and explicit arguments, looks handlers up with `Hash#[]`, and iterates with `while`. No `each` / `map` / `times` / `Array.new { }` / `instance_eval` / `define_method` on the tick path.
- Wire behaviour unchanged: every frame the device answers today gets the same bytes back (ACK `.`, `?`, detail lines, `<touch:N>`, `<A:ready>` / `<A:done>`).
- Face goldens (`spec/golden/face_*.dump`) are unchanged byte for byte.
- `# REQUIRED FOR PY32 COLD-BOOT` and its `puts` lines move with the PY32 init, in the same order, and stay.
- Class bodies in the robot gem reference no device constant at load time (`ILI9342`, `BLE`, `I2C`, …); device constants are read inside methods. The BLE peripheral subclass lives in the app bundle only through `StackChan::Robot::Peripheral.define` (see Task 5).
- Merge only on a passing `/stackchan-device-trial` report.

## Review Focus

1. The tick path allocates no block frames (no `each`/`map` over handler tables) and every handler kind is reachable from `LinkLoop#tick` with at most the depth the current app has.
2. Cold boot keeps the order in CLAUDE.md "cold-boot 初期化" and the `sleep_ms 3000` before `BLE.new`.
3. `apps/robot/app.rb` contains no `$`, no top-level `@`, and nothing but requires and one `StackChan.robot` call.
4. The QEMU gate still loads everything the app bundle loads (requires, device gems incl. the robot gem, the app).

---

### Task 1: Robot gem holds the app's classes, unchanged

**Files:**
- Create: `mrbgems/picoruby-stackchan-robot/{mrbgem.rake, mrblib/stackchan-robot.rb, mrblib/stackchan-robot/{face,head,dispatcher,audio_receiver,ticker,remote,drb_channel,link_loop}.rb}`
- Modify: `app/application.rb` (keeps requires, boot, BLE class; uses `StackChan::Robot::*`), `Rakefile` (`DEVICE_GEM_SOURCES` gains `stackchan-robot` with `mrblib/**/*.rb` sorted; bundle = app's top-level requires + device gems + app), `lib/qemu_gate.rb` probe (same order), `test/picotest/harness.rb` (device suite loads the robot mrblib; extraction of `application.rb` goes), `test/device/*.rb`, `test/face_golden_hash.rb`, `test-host/app_requires_test.rb` if it needs the new list

**Interfaces:** `StackChan::Robot::{Face,Head,Dispatcher,AudioReceiver,Ticker,Remote,DrbChannel,LinkLoop}` with today's methods and constants.

- [ ] Step 1: move each class verbatim into its file under `module StackChan; class Robot; …` (the `Face` subclasses stay for this task). Replace `ILI9342::Color::*` class-body constants with methods or integer literals equal to today's values.
- [ ] Step 2: harness and tests switch to the new constants; all suites green; face goldens unchanged.
- [ ] Step 3: `bundle_app_source` output for `app/application.rb` compiles with picorbc; `rake r2p2:qemu_check` PASS on this tree (records the log). Commit.

### Task 2: Faces are geometry

**Files:** `mrblib/stackchan-robot/face.rb`, `test/device/face_test.rb`, `test/face_golden_hash.rb`, `test/device/face_golden_test.rb`

**Interfaces:** `StackChan::Robot::Face.new(eyes: :open|:closed, mouth: Integer|:open|:none, brows: nil|:angry)` with today's `draw`, `redraw`, `redraw_eyes_open`, `redraw_eyes_closed`. Today's faces are `neutral {}`, `smile {mouth: 8}`, `joy {mouth: 18}`, `sad {mouth: -8}`, `angry {brows: :angry}`, `surprised {mouth: :open}`, `closed {eyes: :closed, mouth: :none}`.

- [ ] Step 1: failing tests: each geometry above produces its golden dump; an unknown key raises `ArgumentError` at construction.
- [ ] Step 2: implement; delete the subclasses; Dispatcher / Ticker hold a `Face` instance instead of a class. Goldens unchanged. Commit.

### Task 3: Handler tables and the robot handle

**Files:** `mrblib/stackchan-robot/{handle,dispatcher,ticker,remote}.rb`, tests under `mrbgems/picoruby-stackchan-robot/test/` or `test/device/`

**Interfaces:**
- `StackChan::Robot::Handle` (`r`): `face(name)`, `led(side, rgb, mode: :solid, flash: nil)` (`flash:` ms → `flash_side`), `head(yaw_left: nil, yaw_right: nil, pitch_up: nil, time: 0)`, `text(s)`, `blink(closed_ms)`, `say_ready?`.
- Dispatcher takes `faces:` (name → Face), `face_index:` ("0" → name), `frame_handlers:` (key → Proc(r, value)); built-in keys stay built in; an unknown key with a handler contributes the handler's truthiness to ACK / `?`; `torque:on` shows `:neutral`, `torque:off` `:closed`.
- Ticker takes `touch_handlers:` (zone Integer → Proc(r)) and `periodic:` (Array of `[period_ms, Proc(r)]`), walks them with `while`; `<touch:N>` notify stays in the engine; blink reopen after `closed_ms` stays in the engine.
- Remote: built-ins plus `remote_handlers:` (Symbol → Proc(r, *args)); `EXPOSED` becomes the built-ins plus the handler names; built-in `stack_free` returns `["<stack_free:N>\n"]` from `Machine.stack_high_water_mark` when that method exists, else `["<stack_free:unknown>\n"]`.

- [ ] Step 1: failing tests per kind (face index, touch zone, frame key, remote, every), each reaching a fake (FakeDisplay / FakeLed / FakeUART servo).
- [ ] Step 2: implement; remove `FACE_TABLE` / `TOUCH_TABLE`. Commit.

### Task 4: `StackChan.robot` DSL

**Files:** `mrblib/stackchan-robot.rb`, `mrblib/stackchan-robot/builder.rb`, tests

**Interfaces:** `StackChan.robot { |bot| … }` → `StackChan::Robot` (not yet booted). `bot.face(name, **geometry)`, `bot.face_index(hash)`, `bot.on_boot { |r| }`, `bot.on_touch(:back|:right|:left) { |r| }` (zones 0/1/2), `bot.on_frame(key) { |r, value| }`, `bot.remote(name) { |r, *args| }`, `bot.every(ms) { |r| }`. `Robot#run` boots and never returns. Missing `:neutral` or `:closed` raises at `StackChan.robot`.

- [ ] Step 1: failing tests: a DSL with one handler per kind, evaluated against fakes through `Robot#wire(display:, led:, head:, touch:, speaker:, notify:)` (the part of boot that does not touch hardware), reaches each fake.
- [ ] Step 2: implement. Commit.

### Task 5: Engine owns cold boot and BLE; `apps/robot/app.rb`

**Files:**
- Create: `mrblib/stackchan-robot/{boot,peripheral}.rb`, `apps/robot/app.rb`, `test/device/app_test.rb`
- Delete: `app/application.rb`
- Modify: `Rakefile` (default robot app `apps/robot/app.rb` for `upload_appmrb` / `deploy_app` / QEMU probe), `lib/qemu_gate.rb` (probe loads the app's requires + gems + evaluates the app's `StackChan.robot` block with `run` replaced by `wire` against no hardware… see Step 3), `lib/device_trial.rb` (per-arm `app:` from `trial/lock.yml`, default `app/application.rb`), `trial/lock.yml` (trial arm `app: apps/robot/app.rb`), `test-host/*` that name `app/application.rb`, `.claude/skills/stackchan-device-*`, `CLAUDE.md`, `README.md`, `HANDOFF.md`

- [ ] Step 1: `Boot` holds today's cold-boot statements in today's order (I2C, AXP2101, AW9523, SPI/LCD, PY32 with the REQUIRED block, LED retry, Closed face, Si12T, servos, speaker, `sleep_ms 3000`) and returns the devices. `Peripheral.define` defines the `< BLE` class (today's `StackChanApp`) when first called on the device, so the gem's class bodies load on the host VM.
- [ ] Step 2: `apps/robot/app.rb`: requires + `StackChan.robot do |bot| … end.run` with today's 7 faces, face index 0–5, touch reactions (back: surprised + both green 60 flash; right: angry + right red 60; left: sad + left blue 60), `bot.every(5000) { |r| r.blink(150) }`. Host test evaluates it against fakes and checks every handler reaches its fake.
- [ ] Step 3: QEMU probe for the robot app: requires + device gems + the app source with `StackChan.robot` evaluated and `run` not called (probe defines `StackChan::Robot#run` as a no-op before the app); `r2p2:qemu_check` PASS. Negative: a Regexp in `apps/robot/app.rb` → FAIL.
- [ ] Step 4: all suites + `test:host` green; commit.

### Task 6: `Machine.stack_high_water_mark` in R2P2-ESP32; the trial checks it

**Files:**
- R2P2-ESP32 `components/picoruby-esp32/picoruby-esp32.c` (mruby VM only): after `mrb_open_with_custom_alloc`, define `Machine.stack_high_water_mark` → `uxTaskGetStackHighWaterMark(NULL)` (bytes on ESP-IDF). Generic, no StackChan name. Branch `claude/stackchan-robot-engine` on `claude/stackchan-protocol-fold`.
- This repo: `lib/qemu_gate.rb` probe prints `QEMU_STACK_FREE=<n>` and the verdict FAILs when it is missing or `< 1024`; `lib/device_trial.rb` step "stack high-water" after every handler kind has run: `stackchan remote stack_free` → FAIL when `< 1024`; `Rakefile` `R2P2_ESP32_REF`, `trial/lock.yml` R2P2-ESP32 pin, `test-host/*`.

- [ ] Step 1: failing host tests: verdict FAILs without / with a low `QEMU_STACK_FREE`; trial step parses `<stack_free:N>` and stops below 1024.
- [ ] Step 2: C method; firmware builds; QEMU PASS with a printed value.
- [ ] Step 3: commit both repos; push R2P2-ESP32 branch.

### Task 7: Pins, dry run, CI

- [ ] `trial/lock.yml` trial arm pins this branch and the R2P2-ESP32 commit; trial dry run (pin → setup → pins → `qemu_check` → build → pins → `sdkconfig.h`) all OK; CI `firmware.yml` green on the branch; HANDOFF "Branches in flight" row for this unit.
