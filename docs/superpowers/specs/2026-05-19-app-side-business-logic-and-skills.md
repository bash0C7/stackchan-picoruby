# App-side Business Logic Migration + Deploy Skills (Design D)

## Goal

1. Move StackChan business logic (`Face` DSL, `Dispatcher`) out of the `picoruby-stackchan-protocol` mrbgem and into the application script (`/home/app.mrb` autostart payload). Firmware retains only stable framework pieces (`FrameParser`).
2. Forbid the on-device `.rb` compile path; require host-side `picorbc` compilation for all device payloads.
3. Surface the recurring deploy operations as project-local skills (`stackchan-device-*`) so that every device interaction goes through a standardized, declarative entry point rather than ad-hoc memory recall.

The motivating defect was a `Guru Meditation Error: InstrFetchProhibited` on `Loading app.rb` caused by the on-device PicoRuby compiler overflowing the main task stack while parsing the production `application.rb` (`new_lit_str` / `codegen` / `gen_values` in the backtrace). The root cause is the deploy path (`r2p2:upload SRC=...rb DST=/home/app.rb`) bypassing host compilation. This design eliminates that path entirely and re-organizes business logic along the cleaner firmware/application boundary the bug exposed.

## Architecture

```
              firmware (build_flash required)            ┃   application (.mrb upload, iterates fast)
                                                         ┃
  picoruby driver gems                                   ┃   /home/app.mrb   (host picorbc -> mrb)
   spi / gpio / i2c / machine                            ┃     [1] requires
   ili9342 / py32-io-expander / stackchan-led            ┃     [2] cold-boot init
   ble (BTstack)                                         ┃     [3] StackchanApp::Face module
                                                         ┃     [4] Face::Neutral.draw(display)
  picoruby-stackchan-protocol  (shrunken)                ┃     [5] sleep_ms 3000 (BTstack yield)
   FrameParser only -- stable framework piece            ┃     [6] StackchanApp::Dispatcher class
                                                         ┃     [7] StackChanApp < BLE peripheral
                                                         ┃     [8] loop { peri.start(60_000) }
```

Dependency direction: application -> firmware (one-way). Firmware never references `StackchanApp::*`.

Iteration cost:
- Firmware change (driver / FrameParser): `rake r2p2:build_flash`, ~5-10 min
- Application change (Face geometry / Dispatcher routing / cold-boot): `rake r2p2:upload_appmrb`, ~7 s

## Components

### Firmware: `picoruby-stackchan-protocol` (shrunken)

| Kept | Removed |
|---|---|
| `mrblib/stackchan_protocol.rb` (FrameParser require/namespace wrapper) | Face module (Base / Neutral / Smile / Joy / Surprised / Closed / Sad / Angry) |
| `mrblib/stackchan_protocol/frame_parser.rb` (48 lines, pure Ruby, low change-frequency) | `mrblib/stackchan_protocol/dispatcher.rb` |
| `test/frame_parser_test.rb` (new if absent) | All Face / Dispatcher / golden tests, `spec/golden/*`, `face:register_golden` rake task (the task itself is migrated to the project-root `Rakefile`, not the mrbgem's) |

### Application: `mrbgems/picoruby-stackchan-protocol/examples/application.rb`

Single-file inline structure (~500-600 lines). Namespace renamed `StackchanProtocol::Face/Dispatcher` -> `StackchanApp::Face/Dispatcher`. `FrameParser` stays in the `StackchanProtocol` namespace (firmware-provided).

```
[1] requires (driver gems + 'stackchan-protocol' for FrameParser)
[2] 5s escape hatch (sleep_ms 5000)
[3] cold-boot init (AXP2101 / AW9523 / SPI / ILI9342 / PY32 / LED)
[4] # === Face module ===
    module StackchanApp::Face
      BROW_OFFSET_Y = 18 ; ...
      class Base ; ... ; end
      class Neutral < Base ; ... ; end
      class Smile / Joy / Surprised / Closed / Sad / Angry
    end
[5] StackchanApp::Face::Neutral.new.draw(display)
[6] sleep_ms 3000 (BTstack yield -- existing fix from project_ble_phase3_btstack_starve_finding)
[7] # === Dispatcher class ===
    class StackchanApp::Dispatcher
      FACE_TABLE = { "0"=>Face::Neutral, ..., "5"=>Face::Angry }.freeze
      ...
    end
[8] # === BLE peripheral ===
    class StackChanApp < BLE
      ...
      @parser     = StackchanProtocol::FrameParser.new   # firmware-provided
      @dispatcher = StackchanApp::Dispatcher.new(display:, led:, stdout: self)
      ...
    end
[9] peri = StackChanApp.new(...)
    loop { peri.start(60_000) }
```

Section dividers via `# ====` comments keep the responsibilities visually separated within the single file.

### New library: `lib/ruby_class_extract.rb`

Project-local library (future gem candidate). Responsibility: extract class/module definitions from a Ruby entry script via prism AST so the file can be `load`ed in host test (CRuby) without resolving its picoruby-only `require`s.

API:

```ruby
require 'ruby_class_extract'

RubyClassExtract.load_classes_from(
  'mrbgems/picoruby-stackchan-protocol/examples/application.rb',
  exclude_superclasses: %w[BLE],   # < BLE classes call picoruby-only methods, skip
)
# After this call, StackchanApp::Face::* and StackchanApp::Dispatcher are loaded
# in the current Ruby process and can be exercised against FakeDisplay / FakeLED.
```

Behavior:
1. `Prism.parse(File.read(path))` -> AST
2. Visit nodes, collect `ClassNode` and `ModuleNode` (top-level and nested). Skip any class whose `superclass` constant name matches `exclude_superclasses`.
3. Re-emit the collected nodes as Ruby source into a `Tempfile`.
4. `Kernel#load(tmpfile.path)`.
5. Tempfile lifecycle: process termination cleans it up.

Library docstring / `lib/ruby_class_extract/README.md` MUST explain the three "why" axes:
1. Why this exists (host-test needs class defs without picoruby-only requires).
2. How it works (AST -> tmpfile -> load).
3. Why this is black magic (production code and test target are the same file; source is parsed and re-synthesized -- not normal test practice).

### Application-side test scaffold

```
lib/
  ruby_class_extract.rb
  ruby_class_extract/version.rb
test/
  test_helper.rb                # require ruby_class_extract; load classes from application.rb
  fake_display.rb               # migrated from mrbgem
  fake_led.rb                   # new
  face_test.rb                  # Face geometry (migrated)
  face_golden_test.rb           # SHA regression (migrated)
  dispatcher_test.rb            # F:0..F:5 dispatch (migrated)
  ruby_class_extract_test.rb    # library unit test
spec/golden/face_*.sha256       # migrated, 4 existing + 2 to register (Phase A HITL)
Gemfile / Gemfile.lock          # prism, test-unit
Rakefile                        # task :test, task 'face:register_golden'
```

## Data Flow

### Cold-boot

```
sleep_ms 5000 (escape hatch)
  -> AXP2101 init (8x I2C write)
  -> AW9523 init (7x I2C write incl LCD reset pulse)
  -> SPI3 init + ILI9342.new
  -> PY32 init + StackchanLed.new + brightness
  -> StackchanApp::Face::Neutral.new.draw(display)
sleep_ms 3000 (BTstack yield)
  -> peri = StackChanApp.new(display, led)
  -> loop { peri.start(60_000) }
```

### Frame ingress -> face / led / ack

```
BLE central writes NUS_RX
  -> StackChanApp#heartbeat_callback (~1s tick)
  -> StackchanProtocol::FrameParser#feed(rx_bytes) -> [Hash, ...]    (firmware-side)
  -> StackchanApp::Dispatcher#handle(hash)                            (app-side)
       FACE_TABLE  -> Face::Sad.new.draw(display)
       MODE_TABLE  -> led.animate_side(side, color, mode)
       stdout.write(ack_byte)
  -> StackChanApp#write(byte) -> @ack_queue
  -> next tick: request_can_send_now_event
  -> ATT_EVENT_CAN_SEND_NOW -> flush_one_ack -> notify
```

### Blink animation (heartbeat 5 ticks ~ 5s)

```
StackchanApp::Face::Closed.new.draw(display)
Machine.delay_ms 150
dispatcher.current_face_class.new.redraw_eyes_open(display)
```

## Rakefile Changes

### Deleted

```
task :upload do  # .rb on-device compile path -- removed entirely (caused crash)
```

### Helper (extracted, shared)

```ruby
def upload_mrb_via_picomodem(src:, dst:, port:)
  picorbc = "#{R2P2_ROOT}/components/picoruby-esp32/picoruby/bin/picorbc"
  abort "picorbc not found" unless File.executable?(picorbc)
  build_dir = File.expand_path('tmp/build', __dir__)
  mkdir_p build_dir
  base = File.basename(src, File.extname(src))
  mrb_path = File.join(build_dir, "#{base}.mrb")
  rm_f mrb_path
  sh picorbc, '-o', mrb_path, src
  abort "picorbc produced no output" unless File.exist?(mrb_path)
  puts "[upload_mrb] compiled #{src} -> #{mrb_path} (#{File.size(mrb_path)} bytes)"
  Deploy::Picomodem.upload(src: mrb_path, dst: dst, port: port)
end
```

### Tasks

```ruby
# Generic: pre-compile and upload to an explicit destination (for /home/lib/* etc).
desc 'host-compile SRC=path/to/foo.rb to .mrb and upload to DST=/home/path/foo.mrb'
task :upload_mrb do
  src = ENV.fetch('SRC') { abort 'SRC=path required' }
  dst = ENV.fetch('DST') { abort 'DST=/home/...mrb required' }
  upload_mrb_via_picomodem(src: File.expand_path(src, __dir__), dst: dst, port: espport)
end

# Autostart payload: SRC=.rb only, DST hard-coded to /home/app.mrb.
desc 'host-compile SRC and upload as autostart payload /home/app.mrb'
task :upload_appmrb do
  src = ENV.fetch('SRC') { abort 'SRC=path required' }
  upload_mrb_via_picomodem(src: File.expand_path(src, __dir__), dst: '/home/app.mrb', port: espport)
end
```

### Callsite updates

- `ble_control_smoke`: `Rake::Task['r2p2:upload_mrb'].invoke` -> `Rake::Task['r2p2:upload_appmrb'].invoke`
- `face_verify`: leg 1 host SHA test path updated to point at application-side `test/`

## Deploy Skills (project-local)

All under `.claude/skills/<name>/SKILL.md`. Slash command aliases for human-facing skills live in `.claude/commands/<name>.md`.

### Atomic skills

| Skill | Mode | Slash alias | Wraps |
|---|---|---|---|
| `stackchan-device-build-flash` | subagent (haiku, 600000ms) | yes | `rake r2p2:build_flash` |
| `stackchan-device-setup` | subagent (haiku, 1200000ms) | yes | `rake r2p2:setup` |
| `stackchan-device-reset` | subagent (haiku, 30s) | yes | `rake r2p2:reset` + 15s settle |
| `stackchan-device-upload-app` | subagent (haiku, 120s) | no | `rake r2p2:upload_appmrb SRC=...` |
| `stackchan-device-upload-lib` | subagent (haiku, 120s) | no | `rake r2p2:upload_mrb SRC=... DST=...` |
| `stackchan-device-wipe` | subagent (haiku, 60s) | yes | `rake r2p2:wipe_storage` + 15s settle |
| `stackchan-device-capture-boot` | main | yes | `bin/capture-with-pty SECONDS /tmp/boot.log rake r2p2:monitor` |
| `stackchan-device-crash-analyze` | subagent (haiku) | no | extract Guru Meditation addresses from log + `addr2line` |
| `stackchan-device-ble-smoke` | subagent (haiku, 300s) | no | `rake r2p2:ble_control_smoke FACE=... COLOR=... MODE=... SIDE=...` |
| `stackchan-device-face-verify` | subagent (haiku, 300s) | yes | `rake r2p2:face_verify FACE=...` |

### Chain skills (happy-path combinations)

| Skill | Slash alias | Composes |
|---|---|---|
| `stackchan-device-deploy-app` | yes | upload-app -> reset (15s settle) |
| `stackchan-device-cold-recovery` | yes | wipe -> upload-app -> reset (15s) |
| `stackchan-device-full-rebuild` | yes | build-flash -> wipe -> upload-app -> reset (15s) |
| `stackchan-device-boot-verify` | yes | reset -> capture-boot 25s -> (if panic dump found, dispatch crash-analyze) |
| `stackchan-device-iterate` | yes | upload-app -> reset -> capture-boot 25s -> (if panic, crash-analyze) |

### Skill content contract

Each `SKILL.md` contains:
- One-line trigger description (matches Claude Code skill auto-trigger conventions)
- Mode (subagent vs main) and rationale
- Exact rake command + env var contract
- Expected pass/fail signal
- Failure escalation hint (which skill to chain to next; e.g. wipe failing -> full-rebuild)

### Reasoning for slash aliases

Human-invoked: yes/no based on whether a developer would type the command directly while pairing with claude.
- `upload-app`, `upload-lib`: low-level, claude composes them inside chain skills.
- `crash-analyze`: AI analysis is the value-add; humans run `addr2line` directly when they want raw output.
- `ble-smoke`: protocol-level smoke driven by claude as part of HITL flow, not a tool a human reaches for ad-hoc.

## Migration Order

1. Implement `lib/ruby_class_extract.rb` (TDD): AST class/module extraction, exclude_superclasses, tmpfile + load.
2. Build project-root `test/` scaffold (`test_helper.rb`, `Gemfile`, fake helpers).
3. Inline `Face` + `Dispatcher` into `application.rb` under `StackchanApp` namespace (host tests only; do not flash yet).
4. Migrate face / dispatcher / golden tests from mrbgem to project test/. Verify all PASS using `RubyClassExtract`-loaded classes.
5. Delete Face/Dispatcher source + tests from mrbgem; shrink `mrblib/stackchan_protocol.rb` to FrameParser wrapper.
6. Update root Rakefile (`upload` deleted, `upload_mrb` DST-required, `upload_appmrb` new, callsite updates, `face:register_golden` migrated, `face_verify` host SHA path updated, `task :test` added).
7. Implement 15 skills under `.claude/skills/` + 11 slash aliases under `.claude/commands/`.
8. Update `README.md` (project structure / iterate cycle / skill catalog) and `CLAUDE.md` (discipline: mrb-only, skill-only device ops, no falling back to legacy memory recipes).
9. Forget memory: delete or update entries that document the old recovery hierarchy / upload conventions, replaced by skills.
10. Commit set (one commit per logical step from 1-9).
11. `stackchan-device-full-rebuild` to flash the shrunken firmware and the new application payload.
12. `stackchan-device-boot-verify` to confirm cold-boot completes and `Face::Neutral` renders.
13. Resume Phase A HITL: sad smoke -> visual ack -> angry smoke -> visual ack -> `face:register_golden` for sad/angry -> `stackchan-device-face-verify FACE=sad/angry` -> commit goldens.
14. Update `project_kawaii_ai_phase_a_code_complete` memory to "Phase A complete" and link to this design.

## Risks

- **Golden SHA drift**: migrated `canonical_dump` must serialize identically to mrbgem original; otherwise existing `face_neutral/smile/joy/surprised.sha256` will need re-registration. Mitigation: copy `canonical_dump` byte-for-byte and run all 4 existing goldens against new test harness before deleting mrbgem.
- **mrbgem shrink build failure**: deleting Face/Dispatcher symbols may require `rake r2p2:setup` if `picogem_init.c` references removed entries. Mitigation: try `build_flash` first; fall back to `setup` if link fails.
- **Cold-boot still crashes after migration**: if the new mrb still triggers a panic on load, root cause is not the on-device compile path -- different debug session needed. Mitigation: `stackchan-device-boot-verify` will catch this and auto-run `crash-analyze`; design D is independently valuable (firmware/app boundary) even if a separate bug remains.
- **`StackChanApp < BLE` not extractable**: classes inheriting from picoruby-only `BLE` cannot be loaded in host CRuby. Mitigation: `exclude_superclasses: %w[BLE]` skips them; BLE-integration coverage is done end-to-end on device via `stackchan-device-ble-smoke`.

## Out of Scope

- BLE protocol changes (frame format stays `<key:val,...>`).
- Servo / touch / WiFi expansion (Phase B+).
- Generalizing skill prefix `stackchan-device-*` to other PicoRuby projects (deferred to future abstraction pass).
- Publishing `ruby_class_extract` as a public gem (kept project-local for now).
- Refactoring `stackchan-led` / `picoruby-esp32` driver gems (those remain firmware-side, unchanged).

## Doc Updates

### `README.md`

Add or rewrite sections:
- Project structure (firmware vs application boundary, file map)
- Iterate cycle (`stackchan-device-iterate`, ~20 s per iteration)
- Skill catalog (table from "Deploy Skills" section)
- Test setup (`bundle install`, `rake test`)
- Recovery flow (one-shot `stackchan-device-cold-recovery`, escalate to `full-rebuild`)

### `CLAUDE.md`

Add as project discipline:
- Device deploys go through `stackchan-device-*` skills; no ad-hoc `rake r2p2:*` invocations in main context.
- `.rb` -> device transfer is forbidden; always `upload_mrb` / `upload_appmrb` (host pre-compile).
- Business logic lives in `application.rb`; firmware retains only drivers + FrameParser.
- Memory entries documenting the old recovery hierarchy or upload conventions are obsolete; do not consult them.

### Memory cleanup

Forget (delete file + remove MEMORY.md entry):
- `project_ble_phase3_wipe_storage_recovery.md` (superseded by `stackchan-device-cold-recovery` skill)
- Any `feedback_*` entry whose only content is `rake r2p2:upload SRC=...rb` advice
- `project_kawaii_ai_phase_a_code_complete.md` resume hint section about `r2p2:upload` -> rewrite or supersede after Phase A HITL closes in step 13-14

Keep (still relevant after migration):
- `project_ble_phase3_btstack_starve_finding.md` (sleep_ms 3000 yield -- still needed in cold-boot)
- `feedback_main_as_orchestrator.md`, `feedback_logwatch_over_sleep.md`, etc. (process discipline, not deploy mechanics)
- `feedback_subagent_no_code_workaround_during_verify.md`
- `project_kawaii_ai_phase_a_code_complete.md` -- update to mark complete after step 13

## Self-Review Notes

Placeholder scan: no TBD/TODO/etc; all migration steps numbered; no unresolved doc paths.

Internal consistency: architecture diagram, components table, data flow, and migration order all agree on `StackchanApp::Face` / `StackchanApp::Dispatcher` / `StackchanProtocol::FrameParser` namespace split.

Ambiguity check: `upload_mrb` (DST required) vs `upload_appmrb` (DST hard-coded) is explicit; chain skills enumerated by exact composition; slash-alias inclusion criterion stated.

Scope: focused on D migration + skills. Phase B (servo) and gem publication explicitly deferred.
