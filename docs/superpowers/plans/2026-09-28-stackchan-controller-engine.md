# StackChan controller engine: implementation plan (DSL step 3 of 6)

> **For agentic workers:** REQUIRED SUB-SKILL: use superpowers:subagent-driven-development to implement this plan one task at a time. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The Mac's behaviour lives in one DSL file, `apps/mac/app.rb` (`App = StackChan.controller do |c| … end`). Everything that file does not arrange is the controller engine in `mrbgems/picoruby-stackchan-controller`: BLE central, link token, ACK/detail, dRuby pair, audio pacing, touch delivery, keepalive while the link is held, reconnect, busy. The controller holds the link only while it is in use. `c.hold(ms)` bounds the keepalive; a command after a release reconnects first; a robot taken by another central is reported busy and retried only on the next action. `picoruby-stackchan-shared` is deleted.

**Architecture:**
- Move the Mac-side classes out of `pc/stackchan-pico/app/*.rb` into the controller gem under `StackChan::Controller`, behaviour unchanged, the same way step 2 moved the robot. The shared gem's `SendBuilder` and errors go with them.
- Pull the link lifecycle out of `Daemon#with_ble` / `start_keepalive` into a plain class, `StackChan::Controller::Link`. It takes an injected clock and runs as a state machine (`:released → :held → :quiet`, plus `:busy`), host-tested against a `FakeRadio` that can drop the link and refuse connects.
- Replace the fixed daemon methods and fixed CLI verbs with an action table filled by the DSL. The daemon's dRuby front and the CLI's verb list both derive from that table.
- `pc/stackchan-pico` keeps only the launchd/process glue: `boot_daemon.rb`, `boot_cli.rb`, `drb_eintr_retry.rb`, `fake_ble.rb`, `bin/stackchan`, the plist.
- Nothing changes in firmware, R2P2-ESP32, picoruby or R2P2-darwin. The Mac VM (`pc:vm_build`) is byte-for-byte what it is today, so `pc:app_bundle` and the TCC grant are unaffected. The gem reaches the Mac VM as source through `load`, as the protocol gem does today.

**Tech stack:** PicoRuby on R2P2-darwin's host VM (CoreBluetooth central, picoruby-drb, `Task`), picotest on the host picotest VM, CRuby test-unit for `test-host/`, launchd.

**Spec:** `docs/superpowers/specs/2026-09-27-stackchan-dsl-design.md`: "Controller engine", "Sharing the robot (one central at a time)", "No global variables", "Testing", "Order" step 3. System plan: `.superpowers/sdd/2026-09-27-system-completion/plan.md`, stage G, H5, G3/G4/G7/G8.

**Branch:** `claude/stackchan-controller-engine` (stackchan-picoruby only), stacked on `claude/stackchan-robot-engine`. It merges after step 2 and after its own trial passes.

## What exists today (facts the tasks rely on)

**`StackchanCentral`** (`pc/stackchan-pico/app/ble_client.rb`):
- `disconnect` only sets `@connected = false`. Nothing resets `@drb_inbox`, `@drb_sent_at` or `@inbox` on disconnect or reconnect.
- `servo_or_read?` does not include `<selftest:run>`. The robot answers selftest with ACK and then a servo detail line (`Dispatcher#handle_selftest` → `emit_servo_detail`). That detail stays in flight and can be taken as the next command's first reply.
- The darwin central (picoruby `port-darwin`, the lineage R2P2-darwin's Rakefile clones for the Mac VM) turns every disconnect into the 3-byte packet `[0x3E, 0x01, 0x05]` (`ports/darwin/ext/Sources/PicoBLEDarwin/PicoBLEPackets.swift:27`, pushed by `PicoBLECentral.swift:261-274`). Byte 0 is LE_META, not 0x05. `BLE#packet_callback` (`ble_central.rb:100-101`) returns from the LE_META branch unless `@state == :TC_W4_CONNECT`, and `StackchanRadio#packet_callback` does not look at it, so the controller never learns that the robot released it.
- A packet reaches Ruby only when something drains (`_event_popped` → `pble_drain_one`, `port-darwin src/mruby/ble.c:63-72`), so the event waits in the Swift FIFO until the next `drain` or `pop_and_dispatch`.
- A write on a dead link is silently dropped: `guard … let p = peripheral else { return }` (`PicoBLECentral.swift:200-204`), and the C side returns 0 (`ble.c:106-110`). On the Mac a write never raises.
- Each process has its own `CBCentralManager`, and `connect` only uses peripherals seen in the current scan (`PicoBLECentral.swift:117-124, 141`). NimBLE does not advertise while it holds a central (`ports/esp32/ble.c:488-496`). So a second process on the same Mac cannot reach the robot while the first holds it.
- The darwin port never calls `cancelPeripheralConnection`. A scan while the robot still holds this Mac finds nothing and costs `CONNECT_TIMEOUT_MS` (15 s).
- `remote` / `write_and_await_ack` clear `@drb_inbox` / `@inbox` per call. `@drb_sent_at` is never reset, and chunks arriving between the clear and the reply are taken as the reply.
- The robot counts every RX, keepalive `<read:pos>` included, as activity (`link_loop.rb:69-77`), releases `release_after` ms after the last one (`link_loop.rb:80-85`), and advertises again after every disconnect (`peripheral.rb:136-139`).

**`Stackchan::Daemon`** (`pc/stackchan-pico/app/daemon_app.rb`):
- No clock. Keepalive is `Task.new { loop { sleep 7; with_ble { read_pos } } }`, which runs forever and cannot be tested.
- `with_ble` reconnects on any `ConnectionError`/`TimeoutError`, including from keepalive. That is a reconnect loop of its own, which the user decisions forbid.
- `start` raises (the daemon dies with `FATAL`) when the robot is taken or absent.
- `stream_audio` uses Kernel `sleep 1.5` / `sleep 0.02`, `stop` uses `sleep 1`, and the CLI's `touch listen` uses `sleep 0.2`. A fake clock can drive none of them.
- The keepalive Task rescues `StandardError` (`daemon_app.rb:222-226`), so no error ends it.
- `chat` runs `respond` outside `with_ble` (`daemon_app.rb:114-125`). The sidecar is asked once per call.
- Touch frames reach `@touch_events` only when something drains: an action, or the keepalive every 7 s.
- The `chat` reply display (`<F:1,text:…>`) and the Japanese zone labels are hard-coded arrangement.

**`FakeRadio`** (`test/pc/fake_radio.rb`):
- `target` and `conn_handle` are fixed at construction.
- `connect_and_discover` only counts calls: it never fails, never resets `conn_handle`, and cannot model a busy robot.
- There is no link drop and no disconnect event.
- There is no auto-answering robot: every ACK is hand-scheduled.
- `FakeClock` (`test/pc/stubs.rb`) exists, and `Machine.board_millis` / `sleep_ms` are routed to it, but nothing in the daemon reads it.

**Other facts:**
- The pc suite extracts class bodies from `ble_client.rb` / `cli_app.rb` / `daemon_app.rb` with `RubyClassExtract` (`test/picotest/harness.rb`). The "shared" suite runs `mrbgems/picoruby-stackchan-shared/test`.
- R2P2-darwin's `build_config/r2p2-stackchan-pc.rb` already leaves the shared gem out of the VM. `boot_daemon.rb` `load`s `errors.rb` and `send_builder.rb` from source. No R2P2-darwin file names the shared gem.
- Everything outside `pc/` reaches the Mac through CLI verbs (`tools/*.rb`, `tools/*.zsh`, `Rakefile` `stackchan_cli!`, `lib/device_trial.rb`). `pc_lifecycle.rb` also calls `status` over DRb. The verb names and output lines are therefore the compatibility surface.
  - `tools/ambient_demo.rb:29-37` loops until `status` prints `ble_connected: true` or `ble_connected=>true`.
  - `tools/latency_baseline.zsh:9-15` states that `pc:up` waits for `ble_connected`.
- `lib/device_trial_ops.rb:42-49` `cli` returns only `status.success?`, so the exit code is not visible.
- `device_trial.rb:159-167` `verdict` needs the operator's answers and `@report["darwin"]`.
- Both launchd daemons log into `/tmp/stackchan-pico` unless `STACKCHAN_LOGDIR` is set (`launch_agent.rb:39-41`, `Rakefile:796`).
- The iOS/watchOS bridge (`r2p2-darwin/bridge/picoruby_bridge.c:159-238`) runs `app.__send__(method, arg)` with `arg` always a String, discards the return value, and hands the caller the captured stdout. The Swift side calls `connect`, a periodic `tick`, and `speak_audio(hex)` (`examples/ios/stackchan/Sources/ContentView.swift:131,159`, `VMExecutor.swift:58-65`).

## Global Constraints

- **Env:** `export PATH=/opt/rbenv/versions/3.3.6/bin:$PATH LC_ALL=C.UTF-8 SCSERVO_RB=<picoruby-scservo clone>/mrblib/scservo.rb`. Suites: `bundle exec rake picotest:run`, `SUITE=pc …`, `bundle exec rake test:host`.
- **CLAUDE.md rules:**
  - No comments (code is How, tests are What, commits are Why); no history wording.
  - Gem layout: `mrbgem.rake` + `mrblib/stackchan-controller.rb` + `mrblib/stackchan-controller/*.rb`. No sibling `require` inside mrblib.
  - Tests are picotest `Picotest::Test` in `test/pc/*_test.rb` (the step 2 convention: engine tests live in the repo's suite dir).
- **pc suite:** runs on CRuby (class enumeration) and on the host picoruby VM (execution).
  - The host VM has a real `Task` and no DRb; DRb is loaded from source.
  - Any `Task` stub stays inside `unless Object.const_defined?(:Task)`.
  - Engine code sleeps only through `sleep_ms` and reads time only through an injected `clock:` (default `-> { Machine.board_millis }`), so `FakeClock` drives every timing test.
- **Wire unchanged:** every verb that exists today writes the same frames in the same order: `<F:n>`, `<L:…>`, `<YL:…>`, `<torque:…>`, `<selftest:run>`, `<read:pos>`, `<text:…>`, `<F:1,text:…>`, `<A:n>` + chunks. Keepalive stays `<read:pos>`.
- **CLI unchanged for existing verbs:** same verb names and the same stdout lines the trial and tools parse: `OK say bytes=N`, `servo detail="<YL_actual:…>"`, `reply=…`, `OK raw`, `OK selftest`, exit 6/7 from calibrate. `led` with missing arguments still prints its usage line and exits 0. `say` keeps `write_without_ack` for the subtitle, so its timing does not change. New: exit 8 means busy.
- **Changed CLI lines, listed in the PR:** `status` becomes one `key=value` line; `touch listen` prints `touch zone=N (back|right|left)` without the Japanese labels.
- **One central at a time:**
  - Only an action may call `Central#connect`. Keepalive, `every`, `poll_touch` and the tick never connect.
  - Every link loss resets the central's dRuby inbox, dRuby send stamp, text inbox and resolved handles, and the daemon's touch queue.
  - A link loss is known as soon as the disconnect packet is drained: the tick drains in every connected state, and `act` drains before it decides whether to connect.
- **No replay.** An action block runs at most once per call. Reconnecting happens before the block, never after a frame of it has been written.
- **No `$` and no top-level `@`** in `apps/mac/app.rb`. The file is exactly `App = StackChan.controller do |c| … end`, with no `require`s (the boot file requires).
- **launchd facts** (CLAUDE.md):
  - Never probe the daemon port by connecting.
  - Always `bootout` + `bootstrap`, never kickstart.
  - Any flow that restarts the daemon mid-trial goes `pc:down` → wait for the robot's release → `pc:up`.
  - The SIGPIPE-on-client-disconnect issue (G9) is not fixed here. New CLI loops must exit between calls, never mid-reply.
- **CLI start-up cost:** `boot_cli.rb` loads only what the CLI uses (`cli.rb`, `calibration.rb`), and a verb costs the same DRb calls as today (attach + one call), so the trial's CLI round-trip timings stay comparable between arms. The CLI sends `act(verb, argv)` directly and fetches `actions` only when the daemon answers `{status: :unknown}`, to print usage.
- **Scope:** no change in R2P2-darwin (pin stays `c0d5aff`), R2P2-ESP32 or picoruby (pins stay step 2's).
- **Merge gate:** merge only on a `/stackchan-device-trial` report with `verdict: pass`.

## Review Focus

1. **The controller never loops.** `connect_and_discover` is reached only from `Link#act`, at most once per action and always before the action's first frame. Keepalive stops `hold` ms after the last action. A keepalive failure marks the link released and does not reconnect. A busy robot produces exactly one scan per user action.
2. **Every loss path resets the link:** the disconnect packet `[0x3E,0x01,0x05]` and `Central#connect` itself each clear `@drb_inbox`, `@drb_sent_at`, `@inbox`, `@connected` and the daemon's touch queue. A late dRuby chunk or ACK from the old link never answers a call on the new one. A release seen by packet costs no ACK timeout. An ACK timeout on a link that is not known lost leaves the link as it is.
3. **No replay.** No action block, `voice.respond` or `on_reply` handler runs twice for one call.
4. **The tick survives.** No handler or link error ends the tick Task.
5. **Token discipline.** Handlers (`on_touch`, `on_reply`, `every`, action blocks) run while the daemon holds the `Task::Queue` token and never pop it again, so there is no deadlock. Touch handlers run after the drain that queued them, never from inside `handle_notification`.
6. **Wire bytes and CLI lines unchanged** for every existing verb. One host test fixes the frames per verb.
7. **`apps/mac/app.rb` holds only the arrangement.** No `$`, no top-level `@`, no class, and nothing but the one `App =` assignment.
8. **The trial checks the machine's answer**: ACK, detail, reply text, exit code or event, not an operator's y/n. Where a person must act (touch), the verdict is still the CLI's output.

---

### Task 1: The controller gem holds the Mac-side classes, unchanged

**Files:**
- Create:
  - `mrbgems/picoruby-stackchan-controller/mrbgem.rake`
  - `mrblib/stackchan-controller.rb` (`module StackChan; class Controller; end; end`)
  - `mrblib/stackchan-controller/{nus,radio,central,daemon,cli,calibration}.rb`
- Move, then delete:
  - `pc/stackchan-pico/app/ble_client.rb`: `NusResolver` → `StackChan::Controller::Nus`, `StackchanRadio` → `StackChan::Controller::Radio < BLE`, `StackchanCentral` → `StackChan::Controller::Central`. The file-level `if Object.const_defined?(:BLE)` goes; `radio.rb` is the only file whose class body names `BLE`.
  - `daemon_app.rb` → `StackChan::Controller::Daemon`
  - `cli_app.rb` → `StackChan::Controller::CLI`
  - `calib.rb` → `StackChan::Controller::Calibration`. It keeps `module_function`; `require "json"` stays as the one cross-gem require.
- Modify:
  - `pc/stackchan-pico/app/boot_daemon.rb`: loads protocol mrblib, the shared files (until Task 2), drb, `drb_eintr_retry.rb`, drb-ble, then the controller mrblib in a fixed order: `stackchan-controller.rb`, `nus`, `central`, `calibration`, `daemon`, `radio` last and only when not `fake`.
  - `boot_cli.rb`: loads only `cli.rb` and `calibration.rb`.
  - `pc/stackchan-pico/app/fake_ble.rb`: namespaces.
  - `test/picotest/harness.rb`:
    - pc suite: `CONTROLLER_MRBLIB = [stackchan-controller.rb, *Dir[stackchan-controller/*.rb].sort]`, loaded after the pc stubs, `PROTOCOL_MRBLIB` and `SHARED_MRBLIB`.
    - Drop `EXTRACTED_*`, `BLE_CLIENT_RB`, `CLI_APP_RB`, `DAEMON_APP_RB`, `CALIB_RB`, the `RubyClassExtract` calls and `require "ruby_class_extract"` in `run`.
  - `test/pc/*.rb`: constants renamed.
- Delete: `lib/ruby_class_extract.rb`, `lib/ruby_class_extract/`, `test-host/ruby_class_extract_test.rb`. Once the harness stops extracting, nothing uses them. Confirm with grep before deleting.
- Create: `test-host/mac_boot_test.rb`, which parses the `load "#{root}/…"` lines:
  - `boot_daemon.rb` loads every controller mrblib file exactly once.
  - `radio.rb` loads only on the non-fake branch.
  - `boot_cli.rb` loads only `cli.rb` + `calibration.rb`.
  - Every loaded path exists.

**Interfaces:** `StackChan::Controller::{Nus, Radio, Central, Daemon, CLI, Calibration}` with today's methods and constants (`Central::CONNECT_TIMEOUT_MS`, `POLLING_UNIT_MS`, `ACK_TIMEOUT_MS`, `DRB_URI`, …; `Daemon::KEEPALIVE_INTERVAL_S`, …; `CLI::VERBS`).

- [ ] Step 1: Move each class verbatim into its file under `module StackChan; class Controller; …`. The error class names (`Stackchan::BLE::*Error`) stay for this task.
- [ ] Step 2: Harness and tests switch to the new constants. `SUITE=pc` is green on the host VM; `test:host` is green, including `mac_boot_test`, `stackchan_wrapper_test`, `launch_agent_test` and `pc_lifecycle_test`.
- [ ] Step 3: `grep -rn "StackchanCentral\|StackchanRadio\|NusResolver\|Stackchan::Daemon\|Stackchan::CLI\|CalibrationMath" -- ':!docs' ':!vendor'` finds nothing. Commit.

### Task 2: The shared gem is folded in and removed

**Files:**
- Create:
  - `mrblib/stackchan-controller/errors.rb`: `StackChan::Controller::{Error < StandardError, TimeoutError, DeviceError, ConnectionError, Busy < ConnectionError}`.
  - `mrblib/stackchan-controller/send_builder.rb`: `StackChan::Controller::SendBuilder`, verbatim, still encoding through `Stackchan::BLE::FrameCodec` from the protocol gem.
  - `mrbgems/picoruby-stackchan-controller/sig/{errors,send_builder}.rbs`, moved from the shared gem with the names changed.
  - `test/pc/send_builder_test.rb`: the four tests of `stackchan_shared_test.rb`, renamed.
- Delete: `mrbgems/picoruby-stackchan-shared/` (README, mrbgem.rake, mrblib, sig, test).
- Modify:
  - `test/picotest/harness.rb`: drop `SHARED_MRBLIB` and the `"shared"` suite.
  - `boot_daemon.rb`: no shared loads.
  - `.rigor.dist.yml`: the signature path moves to the controller gem.
  - `pc/stackchan-pico/app/fake_ble.rb`, every `test/pc/*` (`Stackchan::BLE::*Error` → `StackChan::Controller::*Error`).
  - `test/pc/cli_calibrate_test.rb`: the DRb remote error messages now read `StackChan::Controller::ConnectionError: …`.
  - `README.md` (layout table, "shared suites" line), `pc/stackchan-pico/README.md`.
- Not touched: `rigor.baseline.json`. Retaking it needs rigor on Ruby 4, which the cloud cannot run (G11). Say so in the PR and HANDOFF.

- [ ] Step 1: Move the files and the test. `SUITE=pc` is green, and `rake picotest:run` no longer lists a "shared" suite.
- [ ] Step 2: `grep -rn "stackchan-shared\|Stackchan::BLE::\(Error\|TimeoutError\|DeviceError\|ConnectionError\|SendBuilder\)" -- ':!docs' ':!vendor'` finds nothing. Commit.

### Task 3: Fakes gain a clock-driven robot, link drop and failing connect; the central resets on every loss

**Files:** `test/pc/fake_radio.rb`, `test/pc/stubs.rb`, `mrblib/stackchan-controller/{central,radio}.rb`, `test/pc/{stackchan_central_test,stackchan_central_drb_test,stackchan_radio_test}.rb`, new `test/pc/central_link_loss_test.rb`

**Interfaces (fakes):**
- `FakeRadio.new(services:, conn_handle: 1, target: :fake_target)` keeps today's API and gains:
  - `advertising` (accessor, default true). When false, `connect_and_discover` sets `target = nil`, `conn_handle = BLE::HCI_CON_HANDLE_INVALID` and `services = []`. When true, it restores the constructor values and clears `writes`-in-flight state. Every call is counted (`connect_and_discover_calls`).
  - `fail_next_connects(n)`: the next `n` calls behave as `advertising = false`.
  - `drop_link(event: true)`:
    - Sets `conn_handle` invalid and discards scheduled notifications.
    - With `event: true`, it queues the darwin disconnect packet `[0x3E, 0x01, 0x05]`, which the next `pop_and_dispatch` hands to `packet_callback`. `drain` goes through the same path, so the fake reaches `Radio#packet_callback` exactly as the Mac does.
    - Writes after the drop are recorded in `writes_after_drop` and never answered, as on the Mac.
- `FakeRobotRadio < FakeRadio` is an auto-answering robot:
  - A write to RX of a frame schedules `".\n"` on TX after 1 poll.
  - `<Y…`, `<PU…`, `<selftest:run>` also get `<YL_actual:0,PU_actual:0>\n`; `<read:pos>` gets `<yaw_raw:2048,pitch_raw:2048>\n` instead of the ACK.
  - `<A:n>` gets `<A:ready>\n`. After `n` further RX bytes it sends `<A:done>\n`.
  - `touch(zone)` schedules `<touch:zone>\n` only while the link is up.
  - `rx_frames` lists every frame written.
  - `release_after(ms)`: like the robot's `LinkLoop`, it calls `drop_link(event: true)` once `ms` of `FakeClock` pass without an RX write, and advertises again.
- `FakeClock` stays the time source; `Machine.board_millis` and `sleep_ms` already route to it.

**Interfaces (engine):**
- `Radio#packet_callback`: a disconnect packet is either `getbyte(0) == HCI_EVENT_LE_META && getbyte(2) == HCI_EVENT_DISCONNECTION_COMPLETE` (darwin) or `getbyte(0) == HCI_EVENT_DISCONNECTION_COMPLETE` (btstack-style ports). On either it sets `@conn_handle = HCI_CON_HANDLE_INVALID` and calls `on_disconnect`, then hands the packet to `super`. `Radio` gains `attr_accessor :on_disconnect`.
- `Central`:
  - `#initialize(name_prefix:, radio:, log_fn:)` wires `radio.on_disconnect = method(:link_lost)`.
  - `#link_lost` → `reset_link`, and sets `@lost = true`.
  - `#lost?`
  - `#reset_link`: `@connected = false`; `@drb_inbox.clear`; `@drb_sent_at = nil`; `@inbox.clear`; `@last_detail_frame = nil`; all handles nil.
  - `#connect` calls `reset_link` first and clears `@lost`.
  - `await_inbox`, `await_audio_done` and the dRuby reply wait raise `ConnectionError` as soon as `@lost` is set, instead of waiting out `ACK_TIMEOUT_MS`.
  - `#keepalive` sends `<read:pos>` through `write_and_await_ack`.
  - `detail_expected?(frame)` (renamed from `servo_or_read?`) includes `<selftest:`.

- [ ] Step 1: Failing tests:
  - `Radio#packet_callback` with the exact bytes `[0x3E, 0x01, 0x05]`, and with `[0x05, …]`, invalidates `conn_handle` and calls `on_disconnect` once each. The stub `BLE` in `test/pc/stubs.rb` gains `HCI_EVENT_LE_META = 0x3E` and `HCI_EVENT_DISCONNECTION_COMPLETE = 0x05`.
  - A drop with an event makes the next `drain` call `link_lost`: `connected?` is false, and a late dRuby chunk scheduled before the drop is gone after `connect`.
  - The first `send_chunk` after a reconnect does not sleep (`@drb_sent_at` was reset).
  - A drop with an event during `raw_send`'s ACK wait raises `ConnectionError` at the next poll, not after `ACK_TIMEOUT_MS`.
  - A drop without an event followed by `raw_send` raises `TimeoutError` after `ACK_TIMEOUT_MS`.
  - `connect` against `advertising = false` raises `ConnectionError` and counts one call.
  - `selftest` waits for and keeps its detail line, and the next `raw_send` gets its own ACK.
- [ ] Step 2: Implement. All existing central tests stay green unchanged except for renames. Commit.

### Task 4: `Link`: hold, keepalive, reconnect, busy, with an injected clock (H5)

**Files:** new `mrblib/stackchan-controller/link.rb`; `daemon.rb`; new `test/pc/link_test.rb`; `test/pc/daemon_with_ble_test.rb`, `daemon_stop_test.rb`

**Interfaces:**
- `StackChan::Controller::Link.new(central:, clock:, hold: nil, keepalive_ms: 7_000, log:)`
  - `hold: nil` means hold forever, which is today's behaviour.
  - `state` is one of `:released`, `:held`, `:quiet`, `:busy`.
- `act { … }`, called while the daemon holds the token:
  - In `:held` or `:quiet`, `central.drain` first; then, if `central.lost?`, `lost!`.
  - In `:released` or `:busy` → `connect!`. A `ConnectionError` sets `state = :busy` and raises `Busy` ("robot is held by another controller or unreachable"). This is the only connect in the call.
  - Then `yield`, once. On `ConnectionError`, or on `TimeoutError` with `central.lost?`, → `lost!` and re-raise. A `TimeoutError` with the link still up re-raises and leaves the state as it is. Nothing is yielded twice.
  - On success: `@last_action_at = clock.call`, `state = :held`, `@last_sent_at = clock.call`.
- `tick`, called while the daemon holds the token; never connects:
  - Returns in `:released` and `:busy`.
  - Calls `central.drain` in `:held` and `:quiet`. If `central.lost?` → `lost!` and return.
  - Returns in `:quiet`.
  - If `hold && now − @last_action_at ≥ hold` → `state = :quiet`, log `hold over`, return.
  - If `now − @last_sent_at ≥ keepalive_ms` → `@last_sent_at = now`, then `central.keepalive`, so a keepalive that raises keeps the 7 s pace. A `ConnectionError` → `lost!`. A `TimeoutError` → `lost!` if `central.lost?`; otherwise `state = :quiet`, because the darwin port never cancels the connection, the robot still holds this Mac, and a scan would cost `CONNECT_TIMEOUT_MS` and end in `Busy`. Neither reconnects.
- `lost!` → `central.reset_link`; `state = :released`; `@releases += 1`; the daemon's touch queue is cleared.
- `status` → `{ link: state.to_s, connects:, releases:, last_connect_ms:, hold_ms: }`.
- In `:quiet`, `act` does not rescan first: the robot may still hold the link (it has not reached `release_after`), and while it holds a central it does not advertise, so a scan would cost `CONNECT_TIMEOUT_MS` and fail. The release packet is drained by the tick or by `act` itself, so a released link is `:released` before the action's first frame.
- The built-in `connect` action is `act {}`: it connects only from `:released`/`:busy` and otherwise just counts as use.
- `Daemon`:
  - `#initialize(link:, central:, …)`.
  - `with_link { }` = token pop + `@link.act { }` + token push.
  - `#tick` = token pop + `@link.tick` + dispatch queued touches and due `every` handlers (Task 5) + token push. Each handler call rescues `StandardError` and logs it; link errors inside a handler go through `lost!`.
  - `#start` runs the built-in `connect` action. On `Busy` it logs and still starts DRb, so the daemon stays up and reports busy.
  - `start_keepalive` becomes a `Task.new(name: "tick") { while true; sleep_ms TICK_MS; tick; end }` loop with `TICK_MS = 250`. `tick` itself rescues `StandardError`, so nothing ends the loop. The loop is the only untested line.
  - `stream_audio` uses `sleep_ms 1500` / `sleep_ms 20`; `stop` uses `sleep_ms 1000`.

- [ ] Step 1: Failing tests in `link_test.rb`, with `FakeClock` and `FakeRobotRadio`, `hold: 10_000`, 250 ms ticks:
  - Exactly one `<read:pos>` is written in [0, 10 s) after an action, at 7 s, and none after 10 s; the state is `:quiet` from 10 s.
  - An action at 12 s restarts it: the next keepalive is at 19 s.
  - A keepalive that times out on a link not known lost leaves `:quiet` (no release counted); one whose link drops leaves `:released`. In both, `connect_and_discover_calls` does not grow over 60 s of ticks.
  - A keepalive the robot answers with `?` still runs every 7 s.
  - With the fake robot's `release_after 15_000`, the link is `:released` by 22.25 s (the last keepalive at 7 s + 15 s + one tick), seen by packet.
  - After a release seen by packet, the next `act` calls `connect_and_discover` before its frame and costs zero ACK timeouts. The descriptor (CCCD) writes precede the frame in `rx_frames` order.
  - After `drop_link(event: false)` during `:quiet`, the next `act` raises `TimeoutError` after one `ACK_TIMEOUT_MS` and writes its frame once; it does not rescan while the link is not known lost.
  - A `ConnectionError` inside the block is not retried: the block ran once, the state is `:released`, and the next `act` connects.
  - `advertising = false` → `act` raises `Busy` and `status[:link] == "busy"`. Sixty seconds of `tick` add no connect call. The next `act` after `advertising = true` connects (exactly 2 calls in total).
  - `hold: nil` keeps sending keepalive forever.
  - A touch scheduled while released is never delivered; a touch queued before a loss is cleared by `lost!`.
- [ ] Step 2: The token tests (`daemon_with_ble_test.rb`) are ported: `tick` and a concurrent action serialize on the token. `daemon_stop_test.rb` is ported: `stop` still answers before `DRb.stop_service`. A raising `on_touch` handler is followed by one more `tick` that still delivers the next touch.
- [ ] Step 3: Implement; `SUITE=pc` green. Commit.

### Task 5: The session handle, touch, reply, every

**Files:** new `mrblib/stackchan-controller/session.rb`; `daemon.rb`, `central.rb`; new `test/pc/session_test.rb`

**Interfaces:**
- `StackChan::Controller::Session` (`s`), built once by the engine. Methods, with the frames they write (today's frames):
  - `face(name)` → `<F:n>`
  - `led(side, color, mode: :solid)` → `<L:…>`
  - `servo(yaw_left: nil, yaw_right: nil, pitch_up: nil, time_ms: nil, velocity: nil)` → returns the detail frame
  - `torque(on)`
  - `selftest` → returns the detail frame
  - `read_pos` → `{yaw_raw:, pitch_raw:}` (raises `DeviceError` on `unknown`)
  - `text(s, face: nil)` → `FrameText.build`, sent through `raw_send`
  - `speak_audio(ulaw)`
  - `say(text, gain: nil, rate: nil)` → `"OK say bytes=N"` / `"NG say: synthesis failed or timed out"`
  - `chat(text, speak: true)` → reply or nil
  - `remote(msg, *args)` → Array of lines
  - `state` → `{last_face:, last_say:, last_heard:, last_action:}`
  - `say` and `chat` need a voice (`synthesize`, `respond`). The Mac voice is the sidecar DRb object. Without a voice they raise `ArgumentError`, which is how iOS (step 4) behaves.
- `chat`:
  - `reply = voice.respond(text, state)`, with the daemon's token handed back for the duration of `respond` (`Daemon#unlocked { }` pushes the token and pops it again), so the tick keeps the link alive while the sidecar thinks, as the keepalive Task does today. `respond` runs once per call.
  - Each `on_reply` handler is called with `(s, reply)`.
  - With `speak`, `say(reply)`.
  - Without a reply and with `speak`, the primed fallback audio is streamed.
  - The `<F:1,text:…>` frame is no longer sent by the engine: `apps/mac/app.rb` sends it from `on_reply` (Task 7), so the wire is unchanged.
- Touch:
  - `Central#handle_notification` still routes `<touch:N>` to `on_unsolicited`, which only enqueues `N`.
  - After each `act` and `tick`, the daemon (still holding the token) shifts the queue.
  - For each zone it pushes `{zone: N, name: :back|:right|:left}` onto the listen queue and calls every `on_touch` handler with `(s, name)`.
  - A guard flag keeps a handler's own sends from dispatching touches recursively.
- `every(ms)`: handlers run from `Daemon#tick` only while `link.state == :held`. They never extend the hold and never connect.
- `poll_touch`:
  - Returns the next listen-queue entry.
  - While `:held`, it refreshes `@last_action_at`, because listening is use.
  - When not held it returns `{released: true}` and does not connect.

- [ ] Step 1: Failing tests:
  - A touch scheduled while held reaches `on_touch` with `:right`, and reaches `poll_touch`, within one `tick`.
  - A handler calling `s.face(:joy)` writes `<F:2>` without deadlock.
  - `on_reply` sees the stub reply before `say` streams, and `chat` with no `on_reply` sends no text frame.
  - While the stub voice's `respond` runs, the token queue holds the token, and `respond` is called exactly once.
  - `every(1000)` runs at 1 s steps only while held.
  - `poll_touch` while `:quiet` returns `{released: true}` and makes no connect call.
  - `say` writes `<A:n>`, waits 1500 ms of `FakeClock`, sends 180 B chunks 20 ms apart, and returns on `<A:done>`.
- [ ] Step 2: Implement. Commit.

### Task 6: `StackChan.controller` DSL, actions, built-ins

**Files:** `mrblib/stackchan-controller.rb`; new `mrblib/stackchan-controller/{builder,args}.rb`; `daemon.rb`; new `test/pc/controller_dsl_test.rb`

**Interfaces:**
- `StackChan.controller { |c| … }` → `StackChan::Controller` (not wired). It raises `ArgumentError` without a block.
- Builder calls:
  - `c.action(name, label: nil, flags: []) { |s, arg| }`: `name` is a Symbol, not a built-in and not a method of a `Controller` instance (Kernel's private methods such as `puts` and `sleep_ms` included). `label` is nil or a String. `flags` is an Array of Strings: the `--key` words that take no value for this action.
  - `c.on_touch { |s, zone| }`
  - `c.on_reply { |s, text| }`
  - `c.every(ms) { |s| }`: positive Integer.
  - `c.hold(ms)`: positive Integer.
  - Each call validates like `StackChan::Robot::Builder` (`require_block`, the same message shapes).
- Built-in actions, never re-declared (an `action` with one of these names raises): `:connect, :status, :stop, :raw, :calibrate, :speak_audio`.
  - `calibrate` takes a phase in `arg[0]`: `"begin"` → torque off; `"sample" n` → `{yaw_raw:, pitch_raw:}` as the median of `n` `read_pos`; `"end"` → torque on.
  - `status` does not touch the link and does not count as use.
- `StackChan::Controller::Args.new(words, flags: [])` parses once, in `initialize`, so no reader depends on the order of the others:
  - A `--key` named in `flags` is boolean. Any other `--key` takes the next word as its value, as today's `parse_kw` in `cli.rb` does (`face --x joy` has no positional). `--key=value` is also accepted.
  - `[i]` and `size` read the positionals; `opt(key)`, `int(key)`, `float(key)` read the values; `flag?(key)` reads a declared flag and raises `ArgumentError` for a key the action did not declare.
  - `text`: the whole String when the input is a String (the step 4 bridge passes the user's text unsplit, and `[i]` would split it on whitespace), the positionals joined by `" "` when it is an Array. Text actions (`say`, `chat`, `subtitle`) read `text`, not `[0]`.
  - The Mac CLI sends a plain Array of Strings over DRb; iOS (step 4) passes a String or nil. `Args.new` accepts both.
- `Controller`:
  - `#wire(central:, voice: nil, clock:, log:, port: 8787, host: "127.0.0.1", out: ->(line) { puts line })` → `Daemon`. `out` is where a forwarded action prints.
  - `#act(name, arg)` → `{status: :ok|:busy|:error|:unknown, out:, message:}`. It rescues `Busy` into `:busy` and `StandardError` (the engine's errors and `DRb::DRbConnError`) into `:error`, so the CLI never parses exception class names out of DRb messages. A name that is neither built-in nor declared is `:unknown`.
  - `#actions` → `[[name, label], …]`: the built-ins that make sense as buttons (`connect`, `status`, `stop`), then the app's actions in declaration order.
  - `#respond_to_missing?` / `#method_missing(name, arg = nil)` forward action names to `act` and print the result as the CLI does (`out` lines, `busy: …`, `error: …`) before returning it. The step 4 bridge calls `App.__send__(method, arg)` with a String, drops the return value and shows the captured stdout.
  - `#tick(arg = nil)` delegates to `Daemon#tick`, for the step 4 bridge's periodic call.
  - `#act`, `#tick` and a forwarded action raise `Controller::Error, "wire first"` before `wire`.
  - The built-in `connect` answers `Connected; RX value_handle bound`: the step 4 Swift UI decides that connect succeeded by `result.contains("Connected; RX value_handle bound")` (R2P2-darwin `examples/ios/stackchan/Sources/ContentView.swift:133`, the line iOS `app.rb:363,371` prints).
  - The built-in `speak_audio` decides by transport: a String argument comes from the step 4 bridge and is hex (anything else is `:error`); an Array comes over DRb and carries the raw μ-law bytes in `[0]`.
  - The Builder rejects action names that are `Controller` methods (`tick`, `wire`, `serve`, `act`, `actions`). Loading the gem raises if a built-in name is itself a method of `Controller`, since `method_missing` would never see it.
  - `#serve(port:, host:, name_prefix:, sidecar_uri:)` is the Mac adapter: builds `Radio`/`Central` (or `FakeBleClient` for `fake`), wires, `DRb.start_service(uri, daemon)`, starts the tick Task, joins.
- `Daemon` dRuby front: `act(name, args)`, `actions`, `status`, `stop`, `remote(msg, args)`, `poll_touch`. The old `face`, `led`, … methods are gone. `status` merges `link.status` with `host`, `port`, `ble_connected`, `last_face`, `last_action`.

- [ ] Step 1: Failing tests, one DSL with one of each kind evaluated against `FakeRobotRadio` through `wire`:
  - The action reaches the radio (`rx_frames`), with the label listed by `actions`.
  - `on_touch`, `on_reply` (stub voice) and `every` each run their handler, as in Task 5.
  - `hold` changes when keepalive stops.
  - Builder validation errors: duplicate built-in, non-Symbol name, non-positive `hold`/`every`, missing block.
  - `act(:nope, [])` → `{status: :unknown}`.
  - `Busy` → `{status: :busy}`; `DRb::DRbConnError` from `remote` → `{status: :error}` after `lost!`.
  - `App.__send__(:face, "joy")` writes `<F:2>` and prints `OK face=joy`; `App.__send__(:tick, "")` runs one tick; `App.__send__(:speak_audio, "7f7f")` streams 2 bytes.
- [ ] Step 2: Implement. Commit.

### Task 7: `apps/mac/app.rb`; CLI verbs and daemon methods derive from actions; boot files

**Files:**
- Create: `apps/mac/app.rb`, `test/pc/mac_app_test.rb`
- Modify:
  - `mrblib/stackchan-controller/cli.rb`
  - `pc/stackchan-pico/app/{boot_daemon,boot_cli,fake_ble}.rb`
  - `test/pc/{cli_attach_test,cli_calibrate_test}.rb`, new `test/pc/cli_dispatch_test.rb`
  - `lib/pc_lifecycle.rb`, `test-host/pc_lifecycle_test.rb`
  - `Rakefile` (`pc:up` passes `ALLOW_BUSY`)
  - `test/picotest/harness.rb` (the pc suite loads `apps/mac/app.rb` last)
  - `test-host/mac_boot_test.rb`

**`apps/mac/app.rb`** (arrangement only, today's behaviour):

```ruby
App = StackChan.controller do |c|
  c.hold 10_000
  c.action(:face)     { |s, a| s.face(a[0].to_sym); "OK face=#{a[0]}" }
  c.action(:led)      { |s, a| next "led: side color mode required" if a.size < 3; s.led(a[0].to_sym, a[1].to_sym, mode: a[2].to_sym); "OK led=#{a[0]}/#{a[1]}/#{a[2]}" }
  c.action(:servo)    { |s, a| "servo detail=#{s.servo(yaw_left: a.int('yaw-left'), yaw_right: a.int('yaw-right'), pitch_up: a.int('pitch-up'), time_ms: a.int('time'), velocity: a.int('velocity')).inspect}" }
  c.action(:torque)   { |s, a| s.torque(a[0] == "on"); "OK torque=#{a[0] == 'on' ? 'on' : 'off'}" }
  c.action(:selftest) { |s, _| s.selftest; "OK selftest" }
  c.action(:say)      { |s, a| s.say(a.text, gain: a.float("gain"), rate: a.int("rate")) }
  c.action(:chat, flags: ["no-speak"]) { |s, a| r = s.chat(a.text, speak: !a.flag?("no-speak")); r ? "reply=#{r}" : "reply=(none)" }
  c.action(:subtitle) { |s, a| s.text(a.text); "OK subtitle" }
  c.action(:demo)     { |s, a| … today's verb_demo sequence with block locals and sleep_ms … }
  c.on_reply { |s, text| s.text(text, face: :smile) }
end
```

The exact line strings (the `led` usage line included) are copied from today's `cli_app.rb`. Timeline after an action at T with `hold 10_000`: one keepalive at T+7 s, quiet from T+10 s, the robot releases at T+22 s (the keepalive is RX to the robot). The Mac's own 15–20 s idle drop, counted from the keepalive's answer at T+7 s, lands at T+22–27 s, so which side ends the link first is not fixed; both end as a release, and the trial cannot tell them apart. A `hold` below `release_after` needs no keepalive to survive the hold itself; the keepalive stretches occupancy from T+15 s to T+22 s. `hold 10_000` is set before stage A's reconnect / re-advertise measurement; the HANDOFF says the value is the user's to tune from those timings.

**CLI** (`StackChan::Controller::CLI.run(argv, host:, port:)`):
- It attaches as today and needs no app file.
- Verb resolution, in order:
  1. Engine client verbs: `status` / `stop` / `connect` / `raw` → built-in `act`; `calibrate` → today's client flow over `act(:calibrate, ["begin"|"sample" n|"end"])`; `remote`; `touch listen [--count N] [--timeout S]`; `tui`, now a REPL that runs each line `verb args…` as an action.
  2. Any other verb → `act(verb, argv)`, one DRb call.
  3. On `{status: :unknown}`, it fetches `daemon.actions`, prints usage (the built-ins, then the actions) and exits 1.
- Result printing:
  - `:ok` prints `out` (String, one line per Array element, Hash as `key=value` pairs) and exits 0.
  - `:busy` prints `busy: …` and exits 8.
  - `:error` prints `error: …` and exits 1.
- `status` prints one line of `key=value` pairs: `link=held connects=1 releases=0 ble_connected=true hold_ms=10000 last_face=… last_action=…`. The trial parses it.
- `touch listen` without `--count`/`--timeout` keeps today's endless loop and sleeps `sleep_ms 200` between polls. With them, it exits 0 after N events and 1 on timeout. It first runs `act(:connect)` and exits 1 on `{released: true}`, so it never loops on reconnects.

**Boot files and lifecycle:**
- `boot_daemon.rb`: loads protocol + drb + `drb_eintr_retry.rb` + drb-ble + the controller mrblib + `apps/mac/app.rb`, then `App.serve(port:, host: "127.0.0.1", name_prefix:, sidecar_uri: "druby://127.0.0.1:#{sidecar_port}")`. Today the sidecar port is fixed at 8788 inside the daemon. Pass it as the 4th argv from `LaunchAgent.daemon_job`, so the trial's second daemon (Task 8) can use 8798. `launch_agent_test` covers it.
- `pc_lifecycle.rb#up`:
  - Requires `status[:connects].to_i >= 1`. Replaces `ble_connected`: under hold, the link may already be quiet or released by the time `status` answers.
  - With `config[:allow_busy]`, `status[:link] == "busy"` also passes.
  - Otherwise, busy raises `Error, "robot is held by another controller: …"`.
  - `Rakefile pc_lifecycle` reads `allow_busy: ENV["ALLOW_BUSY"] == "1"` and `sidecar_port` is threaded to the daemon job.
- `tools/ambient_demo.rb` `wait_until_connected` runs `stackchan connect` until it exits 0 (exit 8 = retry after 3 s) instead of matching `ble_connected` in `status`. `tools/latency_baseline.zsh` says `pc:up` waits for the first connect.
- `pc/stackchan-pico/app/fake_ble.rb` (`BLE_FAKE=1`) gains `lost?`, `reset_link`, `drain`, `keepalive` and `remote`, so `Link` runs on it.

- [ ] Step 1: Failing tests:
  - **`mac_app_test.rb`:** loads `apps/mac/app.rb` against `FakeRobotRadio` + a stub voice (`"stub返答:#{prompt}"[0, 19]`, 80 B per character). For every action it asserts the exact frames and the returned line:
    - `face joy` → `<F:2>` / `OK face=joy`
    - `led both green solid`
    - `servo --yaw-left 50 --pitch-up 30 --time 500` → `<YL:50,PU:30,T:500>` and `servo detail="<YL_actual:0,PU_actual:0>\n"`
    - `torque on`
    - `selftest`
    - `say`, via `OK say bytes=`
    - `chat こんにちは` → `<F:1,text:stub返答:こんにちは>`, then `say`'s `<text:…>` subtitle, then `<A:n>`, as today (`daemon_app.rb:103-107, 119-120`), and `reply=stub返答:こんにちは`
    - `led both` → no frame and `led: side color mode required`, exit 0
    - `demo --duration 1`
  - **`cli_dispatch_test.rb`** (scripted daemon):
    - A verb that is in `actions` is sent as `act(verb, argv)`.
    - A verb that is not in `actions` prints usage and exits 1.
    - `busy` exits 8.
    - `touch listen --count 1 --timeout 2` exits 0 on an event and 1 on timeout.
    - `status` prints the `key=value` line.
  - **`cli_calibrate_test.rb`:** ported to the phased `act` and still exits 6/7/1 as today.
  - **`ambient_demo`:** a test-host case for `wait_until_connected` with a stubbed CLI (exit 8, then 0).
  - **`pc_lifecycle_test.rb`:** `connects: 0` fails; `link: "busy"` fails without `allow_busy` and passes with it.
  - **`mac_boot_test.rb`:** `boot_daemon.rb` loads `apps/mac/app.rb` after the gem and calls `App.serve`. The app file has no `require`, no `$`, no top-level `@`, and exactly one top-level statement, `App = StackChan.controller …` (checked with prism).
- [ ] Step 2: Implement. Delete `CLI::VERBS`, `Daemon#face` … `#sample_pose`, and `TOUCH_ZONE_LABELS`. `touch listen` prints `touch zone=N (back|right|left)`; the Japanese labels were arrangement nobody declared, so they go. Flag this line change in the PR.
- [ ] Step 3: `SUITE=pc`, the full picotest run and `test:host` are green. `tools/*.rb|zsh` and `Rakefile` `stackchan_cli!` call only verbs that still exist, and nothing outside the trial parses `status` output (grep `ble_connected` and `status`). Commit.

### Task 8: The trial drives the controller and checks it by machine

**Files:** `lib/device_trial.rb`, `lib/device_trial_ops.rb`, `test-host/device_trial_test.rb`, `trial/lock.yml` (trial arm `controller: true`)

**Interfaces:**
- **ops:**
  - `cli(root, *args, env: {}, stdin: nil)`: `Open3.capture2e(env, cli, *args, stdin_data: stdin.to_s)`, returning the output and `status.exitstatus`, so a step can tell exit 8 from exit 1.
  - `sleep(seconds)`.
  - `notice(text)`: prints `[trial] >>> text` for the operator.
  - The fake ops in the test record all three.
- **Timings** come from the arm itself. `release_after` is parsed from the arm's app file (`/release_after\s+([\d_]+)/` on `ops.read(File.join(wt, arm["app"]))`); `hold` comes from the `hold_ms=` field of `stackchan status`. `quiet_wait_s = (hold + release_after) / 1000 + 5` (both in ms). After an action at T the robot has released by T + hold + release_after at the latest, because the last keepalive comes before T + hold.
- **New steps** run in the trial arm only when `arm["controller"]`, after `measure` and before `stack high-water`. The touch step runs the robot's `on_touch` handler, so the stack reading now comes after every robot handler kind:

| step | drives | machine check |
|---|---|---|
| `selftest detail` | `stackchan selftest` | output matches `DETAIL` |
| `touch listen` | `notice("touch the back of the head")`, then `cli touch listen --count 1 --timeout 30` | exit 0 and `touch zone=\d`. Without a TTY on stdin the step is `incomplete` (as the questions are), not a stop |
| `calibrate` | `cli calibrate --no-torque-toggle --format json --samples 3`, `stdin: "\n" * 5` | exit 0; the last output line parses as JSON (the prompts are on stdout before it); `servo_yaw_zero`/`servo_pitch_zero` are Integers; `forward_verify` deltas ≤ 3 |
| `chat (sidecar STUB)` | `rake pc:down`, `sleep quiet_wait_s`, `rake pc:up` with `STUB=1`, then `cli chat こんにちは`; after the arm, `pc:down` and `pc:up` without `STUB` so the Mac is left on the real sidecar | output is exactly `reply=stub返答:こんにちは`. The reply was spoken, so `<A:done>` came back; the CLI would otherwise fail |
| `release and reconnect` | `cli face neutral`; `status` → `connects` c0; `sleep quiet_wait_s`; `status` → `link` (the tick drains in `:quiet`, so `released` here means the release packet arrived); timed `cli face joy`; `status` | the face is OK and `connects == c0 + 1`. Detail: `release seen: yes/no, reconnect + face N.NN s` |
| `hand-off Mac A → Mac B → Mac A` | `rake pc:up NS=handoff STACKCHAN_PORT=8797 STACKCHAN_SIDECAR_PORT=8798 STACKCHAN_LOGDIR=/tmp/stackchan-pico-handoff STUB=1 ALLOW_BUSY=1`; `sleep quiet_wait_s` (whatever B's start-up connect did has been released); `cli face neutral` on A; at once `cli face joy` with env `STACKCHAN_PORT=8797`, started less than 7 s after A's call returned (the step records the gap and stops if it is not); `sleep quiet_wait_s`; timed `face joy` on B; `sleep quiet_wait_s`; timed `face neutral` on A; `rake pc:down NS=handoff` | B's first `face` exits 8 with `busy:`; B's second and A's last exit 0 with `OK face=`. Each reconnect time is recorded in `timings["hand-off B"]` / `["hand-off A"]` |

The `pc:up` in the chat row passes `env: {"STUB" => "1"}`. The rest of the arm then runs against the STUB sidecar; the audio question refers to the earlier `say`.

- **`verdict`:** unchanged. The new steps are steps; they add no questions. `verdict` still needs the operator's answers (servo moved, subtitle intact, audio without gaps) and `trial:darwin` (`device_trial.rb:159-167`), so step 3's merge gate still includes those; replacing them by machine checks is step 4's `trial:darwin` work and is stated in the PR and HANDOFF.
- **`markdown`:** the new timing series appear in the table (the base arm cells show `—`).

- [ ] Step 1: Failing test-host tests:
  - Each step's pass path.
  - Each machine check's failure stops the arm with the named reason:
    - a wrong reply text
    - `touch listen` exits 1
    - calibrate exits 6
    - `connects` does not grow
    - B is not busy (exit 1 instead of 8)
    - B's first call starts 7 s or more after A's
    - B never connects
  - Ordering:
    - `pc:down` → sleep → `pc:up` with `STUB=1` before `chat`
    - hand-off B's `pc:up` carries `NS`/ports/`ALLOW_BUSY`
    - `stack high-water` comes after `touch listen`
  - The base arm (no `controller`) calls none of these.
  - `quiet_wait_s` is computed from the arm's app file and `status`, in seconds: `hold_ms=10000` + `release_after 15_000` → 30.
  - The touch step without a TTY is `incomplete`; the chat step restores the real sidecar after the arm.
- [ ] Step 2: Implement. `test:host` green. Commit.

### Task 9: Docs, pins, dry run, CI, PR

- [ ] **`CLAUDE.md`:**
  - The "PC" line: the controller gem, `apps/mac/app.rb`, and that `pc/stackchan-pico` is glue only.
  - Test section: the pc suite loads the controller mrblib + `apps/mac/app.rb` with `FakeRadio` / `FakeRobotRadio`; no class extraction.
  - BLE notes: hold/keepalive, exit 8 = busy, `touch listen --count/--timeout`.
  - "Driver gems" line: shared gem gone.
- [ ] **`README.md`**, **`pc/stackchan-pico/README.md`:** verbs come from `apps/mac/app.rb`; add `status` fields and exit 8.
- [ ] **`trial/lock.yml`:** the trial arm's `stackchan-picoruby` goes to this branch's head; `controller: true`. R2P2-ESP32 `850e9e8`, picoruby `9c4636a`, repos, aot and darwin `c0d5aff` are unchanged. This step changes no firmware, but both arms still build and flash per the lock.
- [ ] **Trial dry run all OK:** pin → setup → pins → `r2p2:qemu_check` (PASS; the robot app is unchanged) → build → pins → `sdkconfig.h`.
- [ ] **CI:** `firmware.yml` green. It runs `picotest:run` (pc suite included) and `test:host`. `deps.yml` green.
- [ ] **HANDOFF:** a "Branches in flight" row, "DSL step 3: controller engine + `apps/mac/app.rb`, shared gem removed". It records the host-green state and the unverified items below.
- [ ] **PR** in stackchan-picoruby, stacked on step 2's PR.
  - Body: the Review Focus list, the CLI changes (`status` line format, `touch listen` zone names, `tui` over actions, exit 8), and the Mac-only risks.
  - End the body with the attribution lines from the session's system reminder.

## Risks only the Mac can verify

The darwin port's side is settled from code (see "What exists today"): the disconnect arrives as `[0x3E,0x01,0x05]`, a write on a dead link is dropped silently, and a second process on the Mac cannot reach the robot while the first holds it. What stays open is timing and OS behaviour:

1. **Rediscovery after a peripheral-side release.** Whether `connect_and_discover` finds the robot again within `CONNECT_TIMEOUT_MS` (15 s). CoreBluetooth may filter duplicate advertisements. The `release and reconnect` timing measures it.
2. **Which side ends an idle link.** The robot at T+22 s or the Mac's own idle drop at T+22–27 s. Both are a release; the trial records the reconnect cost, not the side.
3. **launchd.**
   - The chat step's `pc:down` → wait → `pc:up STUB=1`: a dead daemon sends no RX, so the robot releases within `release_after`; the step's wait covers it.
   - `pc:up` now accepts a daemon whose link is already quiet (`connects >= 1`).
   - The second daemon's plist carries the new sidecar-port argv and its own log dir.
   - All of this runs only under `launchctl` on the Mac.
4. **`gets` from a pipe** in the Mac VM for `calibrate`'s stdin-fed prompts (the trial's calibrate step).
5. **SIGPIPE (G9)** is still open. The trial's CLI calls all exit after a complete reply; an interactive `touch listen` stopped with Ctrl-C can still kill the daemon, as today.
6. **`rigor.baseline.json`** is not retaken (rigor needs Ruby 4, which the cloud lacks). The files it names move.
7. **`hold 10_000`** is chosen before stage A's reconnect measurement; the trial's timings decide the final value.

### Critical Files for Implementation
- /home/user/stackchan-picoruby/pc/stackchan-pico/app/daemon_app.rb (becomes `mrbgems/picoruby-stackchan-controller/mrblib/stackchan-controller/{daemon,link,session}.rb`)
- /home/user/stackchan-picoruby/pc/stackchan-pico/app/ble_client.rb (becomes `…/stackchan-controller/{nus,radio,central}.rb`)
- /home/user/stackchan-picoruby/test/pc/fake_radio.rb (link drop, failing connect, `FakeRobotRadio`)
- /home/user/stackchan-picoruby/test/picotest/harness.rb (pc suite loads the gem + `apps/mac/app.rb`; shared suite and extraction removed)
- /home/user/stackchan-picoruby/lib/device_trial.rb (the controller steps, with `test-host/device_trial_test.rb`)