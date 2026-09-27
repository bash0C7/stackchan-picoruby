# StackChan engine + DSL — design

## Goal

Every StackChan app splits into an engine that stays fixed and an arrangement that is rewritten per
occasion. The arrangement is Ruby DSL only: blocks handed to the engine, which yields them. No global
variables. Everything StackChan lives in stackchan-picoruby; the platform repos know nothing about it.

Apps: the robot (CoreS3), the Mac daemon + CLI, the iPhone app, the Apple Watch app.

Success:

- Changing what StackChan does (faces, touch reactions, LED, accepted frames, dRuby methods,
  buttons, CLI verbs, conversation) edits one DSL file in stackchan-picoruby and nothing else.
- R2P2-ESP32 and R2P2-darwin contain no StackChan name, path or gem.
- No `$` variable and no top-level instance variable in any app.
- The robot passes `/stackchan-device-trial` with the DSL app, including a measured stack high-water
  mark for the per-tick handler path.

## Repositories

| repo | holds |
|---|---|
| stackchan-picoruby | engines, wire format, the four DSL apps, iOS/Watch Swift + `project.yml`, every StackChan build config |
| R2P2-ESP32 | ESP32 platform; takes an external build config and gem dirs |
| R2P2-darwin | Apple platform; builds an external app dir with an external build config; bridge calls a constant |
| picoruby-ili9342 / picoruby-scservo / picoruby-py32-io-expander | hardware drivers, unchanged |
| picoruby-stackchan-protocol | folded into stackchan-picoruby, then archived |

Dependencies point one way: stackchan-picoruby → platforms and drivers.

## stackchan-picoruby layout

```
mrbgems/
  picoruby-stackchan-protocol/    wire format: FrameParser (parse), FrameCodec (encode),
                                  face indices, LED colours, NUS + dRuby UUIDs, FrameText
  picoruby-stackchan-robot/       robot engine + `StackChan.robot` DSL
  picoruby-stackchan-controller/  controller engine + `StackChan.controller` DSL
  picoruby-drb-ble/               unchanged
  picoruby-stackchan-led/ picoruby-si12t/ picoruby-aw88298/   drivers, unchanged
apps/
  robot/app.rb                    robot DSL (replaces app/application.rb)
  mac/app.rb                      Mac daemon + CLI DSL (pc/stackchan-pico keeps launchd glue)
  ios/app.rb, ios/Sources/*.swift, ios/project.yml
  watchos/app.rb, watchos/Sources/*.swift, watchos/project.yml
build_config/
  esp32-stackchan.rb              firmware gem list (moved from R2P2-ESP32)
  darwin-stackchan-{pc,ios-device,ios-sim,watchos-device,watchos-sim}.rb   (moved from R2P2-darwin)
```

`picoruby-stackchan-shared` disappears: its codec and tables go to protocol, `SendBuilder` to the
controller.

## Robot engine

Owns: cold-boot hardware order (AXP2101, AW9523, PY32 with the `# REQUIRED FOR PY32 COLD-BOOT`
block, LCD, LED, servos, touch, speaker), `sleep_ms 3000` before BLE, the BLE peripheral, the
per-tick loop with `_event_popped` every tick, audio half-duplex, the dRuby front, the built-in
frame keys (`F`, `L`, `text`, `YL`/`YR`/`PU`, `T`/`V`, `A`, `torque`, `selftest`, `read`), ACK `.` /
error `?` and the servo detail line.

DSL (`StackChan.robot do |bot| … end`, evaluated once at boot):

| call | effect |
|---|---|
| `bot.face name, **geometry` | defines or overrides a face (eyes, mouth, brows) |
| `bot.face_index index => name` | maps the wire index of `F` to a face |
| `bot.on_boot { \|r\| … }` | runs after cold boot, before advertising |
| `bot.on_touch(zone) { \|r\| … }` | zone is `:back`, `:right`, `:left` (Si12T zones 0, 1, 2) |
| `bot.on_frame(key) { \|r, value\| … }` | handles a frame key the engine does not own; the block's truthiness is the part's result for ACK / `?` |
| `bot.remote(name) { \|r, *args\| … }` | adds a method to the dRuby front (allow-listed) |
| `bot.every(ms) { \|r\| … }` | periodic arrangement (idle blink, ambient LED) |

`r` is the robot handle: `face`, `led(side, colour, mode:, flash: ms)`, `head(yaw_left:, yaw_right:,
pitch_up:, time:)`, `text`, `say_ready?`. It is one object built by the engine; handlers receive it
as an argument.

## Controller engine

Owns: BLE central scan/connect/reconnect, the `Task::Queue` link token, text frames with ACK and
detail, the dRuby pair (`remote`), audio blast pacing, touch notifications, keepalive.

DSL (`StackChan.controller do |c| … end`):

| call | effect |
|---|---|
| `c.action(name, label: nil) { \|s, arg\| … }` | a named operation; a Mac CLI verb, an iOS/Watch button (label shown) |
| `c.on_touch { \|s, zone\| … }` | touch notification from the robot |
| `c.on_reply { \|s, text\| … }` | an AI reply before it is spoken (Mac sidecar) |
| `c.every(ms) { \|s\| … }` | periodic arrangement |

`s` is the session handle: `face`, `led`, `servo`, `torque`, `text`, `say` (where a TTS provider
exists: Mac sidecar; on iOS the Swift synthesiser feeds `speak_audio`), `remote(:method, *args)`,
`read_pos`.

Built-in actions stay in the engine and are not re-declared: `connect`, `status`, `stop`, `raw`,
`calibrate`, `speak_audio`.

## Execution model (8 KB VM stack on the robot)

- DSL blocks are evaluated once, at boot, on a shallow stack. `instance_eval` / `define_method` are
  used only there, never on the tick path.
- Handlers are stored as Procs and called from Ruby (`LinkLoop`, `Ticker`) with explicit arguments.
  No handler is called from a C callback.
- The tick path uses `while` and C methods; the engine keeps its handler tables as Hashes looked up
  with `[]`, not iterated with blocks.
- The trial measures the stack high-water mark of `picoruby_task` after exercising every handler
  kind, and fails when less than 1 KB of the 8 KB is left. The reading comes from
  `uxTaskGetStackHighWaterMark`; if R2P2-ESP32 exposes no Ruby method for it, step 2 adds one there
  as a generic platform method.

## No global variables

- Robot: the top-level `@head` / `@touch` / `@speaker` become engine internals.
- iOS / Watch / Mac: the R2P2-darwin bridge resolves a constant `App` instead of `$app`
  (`App.__send__(method, arg)`). Every R2P2-darwin example assigns `App = …`. The controller DSL
  returns the object to assign.
- Swift reads `App.actions` (name + label) and renders one button per action; adding an action adds
  a button.

## Platform changes

- R2P2-ESP32: the build reads the build config path and extra gem dirs from the environment
  (`R2P2_BUILD_CONFIG`, `R2P2_GEM_DIRS`); its own default config lists no StackChan gem.
  Written so it can go upstream.
- R2P2-darwin: the per-app rake definition takes `APP_DIR` and `MRUBY_CONFIG` from the caller;
  `examples/{ios,watchos}/stackchan`, the stackchan build configs and `watchos:stackchan` tasks are
  deleted. The bridge's `$app` becomes `App` for all examples.
- stackchan-picoruby Rakefile: `ios:*`, `watchos:*` and `pc:vm_build` call into `vendor/R2P2-darwin`
  with `apps/<target>` and `build_config/darwin-stackchan-*.rb`; `r2p2:*` passes
  `build_config/esp32-stackchan.rb` to `vendor/R2P2-ESP32`.

## Testing

- Host picotest per gem: protocol (parse ↔ encode round trip, the multibyte case), robot engine with
  the existing fakes, controller engine with `FakeRadio`, DSL evaluation (a handler per kind reaches
  the fake hardware).
- The four DSL apps each have a host test that evaluates them against fakes.
- Face goldens stay (`spec/golden`), re-registered only if a face's geometry is defined differently.
- Not testable in the container: Swift UI, Xcode builds, the darwin VM, the robot — covered by
  `/stackchan-device-trial` and `trial:darwin`, whose lock gains the R2P2-darwin and R2P2-ESP32
  platform pins.

## Order

Development of each step stacks on the previous branch without the robot. Nothing merges before its trial passes, and a step merges only after the step before it. Each step ends with its own trial.

1. Fold picoruby-stackchan-protocol + the shared codec into `mrbgems/picoruby-stackchan-protocol`;
   firmware takes it as a gem dir.
2. Robot engine + `apps/robot/app.rb`.
3. Controller engine + Mac (`apps/mac/app.rb`), shared gem removed.
4. R2P2-darwin platform shape + `App` constant; iOS/Watch move to `apps/`, buttons from actions.
5. R2P2-ESP32 external build config; StackChan gem list moves to `build_config/esp32-stackchan.rb`.
6. Archive picoruby-stackchan-protocol.

## Out of scope

Driver gems' APIs, the wire format itself, AOT kernels, picoruby-multicore.
