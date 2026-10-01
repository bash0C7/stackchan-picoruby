# HANDOFF

Where the work stands and what comes next. **Current state only.**

Rewritten in place, never appended to. It carries no history: a reader arriving
cold has no reference point for a past state, so "previously" and "as of
<date>" do not belong here. Durable knowledge does not belong here either —
README.md is what the robot is and does, CLAUDE.md is how to work on it, and
specs, plans and reviews live in the Obsidian vault under
`02_dev_docs/stackchan-picoruby/`.

## Now

The robot works, and every subsystem it has has been driven on the hardware:
cold boot, BLE link, faces, LEDs, servos on both axes, head touch, audio, and
selftest. Servo absolute positioning — the point of the whole thing — lands
where it is told: commanding yaw-left 50 with pitch-up 30 reads back
`<YL_actual:50,PU_actual:29>`, and yaw-right 40 with pitch-up 10 reads back
`<YR_actual:39,PU_actual:9>`.

| Piece | Revision |
|---|---|
| `stackchan-picoruby` | `main` @ `0a65507`, pushed |
| firmware tree `vendor/R2P2-ESP32` | `c-primitives-verified` @ `2f18720` |
| picoruby submodule under it | `7258676` |
| LCD driver gem | `bash0C7/picoruby-ili9342` `main` @ `01a1a02` |
| speaker gem | `mrbgems/picoruby-aw88298` here, fetched from `main` by the build_config |

The device reports App version `2f18720`, so it is running this tree.

Tests pass: 476 picotest across device, pc, shared, aot, drb-ble and the three driver gems,
with no failures, crashes or skips, plus the CRuby host tests, where ten cases
are omitted on machines without `plutil`. Both workflows are green on the tip
of `main`.

`rake test` runs `rigor:check` first, a host-side type analysis that fails
on any diagnostic absent from `rigor.baseline.json`. It needs `rake vendor:setup`
to have run, and installs its own gemset into `vendor/rigor-tool` on first use.
Seventeen diagnostics are frozen in the snapshot; eight of them are false
positives from rigor 0.3.7 and the rest are stated invariants the code does not
declare. `docs/rigor.md` is the reference. `deps.yml` runs on every push; `firmware.yml` runs weekly and on
demand, so trigger it with `gh workflow run firmware.yml` after changing
anything it covers.

## In flight: PR #11, not yet mergeable

Everything below `main` is on `claude/ecstatic-allen-s6qki1` (PR #11 → `main`,
not pushed). It carries:

- dRuby over BLE and the AOT kernels (`ulaw_decode`, `glyph16`)
- picoruby-multicore on core 1
- the deterministic QEMU boot gate
- the DSL work: robot engine + `apps/robot/app.rb`, controller engine +
  `apps/mac/app.rb`, `apps/ios` + `apps/watchos`, and the firmware gem list in
  `build_config/esp32-stackchan.rb`
- device tooling that picks the CoreS3 by USB serial
- the pre-merge device check, `acceptance/`

`acceptance/lock.yml` pins the one firmware:

| repo | branch | sha |
|---|---|---|
| R2P2-ESP32 | `claude/external-build-config` | `9716605` |
| picoruby (fork, under R2P2-ESP32) | `claude/ble-peripheral-disconnect` | `9c4636a` |
| R2P2-darwin | `claude/external-app` | `7a02219` |
| picoruby-ili9342 | `claude/aot-glyph16` | `6adc482` |
| picoruby-py32-io-expander | `claude/simplify` | `8f8b3d3` |
| picoruby-scservo | `claude/simplify` | `1e3a18b` |
| suppify | `claude/string-arg-length` | `a5449a3` |

The robot runs this firmware and the app of `979eb09`. The acceptance report
is `acceptance/results/20260929-093450` (uncommitted).

### What the branch changed on the way to a pass

- `915a550`: the revert guard skips a test-host file that cannot load at the
  base, so the branch can be pushed.
- `254c44d`: acceptance is one full `acceptance:check` run by the owner in a
  TTY (or a tmux session Claude drives, with the owner answering in chat). No
  pc_vm, no multi-Mac hand-off, chat against the real sidecar and last, `say`
  reads "こんにちは", a question asks about distortion, no darwin in the verdict.
- `1aae757`: a head nobody touches within 30 s is recorded and neither stops
  the run nor blocks `pass`.
- `d56cb1b`: `DRbBle::Responder` frames requests itself instead of raising
  `Incomplete`. One raise + rescue costs about 1.8 KB of C stack.
- `c75f9d5`: the LED buffer is filled with `while`; `Array.new(n) { }` nested
  the VM and left the picoruby task 488 B of stack at cold boot.
- `979eb09`: the stack floor is 512 B. The remaining depth is the ILI9342
  primitives calling `SPI#write` / `GPIO#write` through `mrb_funcall`.
- The TTS gain stays at 0.05 (`7ef5b1e` was reverted by `6e271c3`).

### The last acceptance run

Every step through the questions passed: stack high-water `888 B free`, the
five answers all `y` (the owner heard no distortion). It stopped at
`torque off` because the Mac daemon froze; `chat` has not run against the real
sidecar yet. Two earlier runs failed on one-offs recorded in #22: a pitch
`read_pos` that failed three times, and the daemon dying of SIGPIPE.

## Next

### 1. Not mergeable yet: the Mac daemon freezes

The robot is powered off. Evidence is in the vault:
`02_dev_docs/stackchan-picoruby/review/2026-10-01-daemon-freeze/`.

What is measured:

- Twice the daemon stopped accepting dRuby connections mid-acceptance; a CLI
  stayed `ESTABLISHED` while the daemon held only its LISTEN socket.
- Every task stopped: the tick task's 10 s heap log stopped too. The heap was
  never the cause (about 750 KB used of 6.4 MB, flat).
- Daemon 15112: 0 % CPU, `sample` shows only the scheduler's `usleep`.
- Daemon 55951: 99.8 % CPU for hours; `spindump` shows all 501 samples inside
  `mrb_task_queue_push`, whose only loop walks `q_waiting_` in
  `queue_wake_one_waiter` (mruby-task `task_queue.c`). The list had a cycle.
- dtrace over 15 s on a fresh daemon: `mrb_tick` ran 3,736 times on the main
  thread and 3 times on two other threads. `mrb_task_queue_push` ran only on
  the main thread (60 calls, from `Task::Queue#push`); `BLE_heartbeat` did
  not push in that window.

What the code says:

- The POSIX scheduler excludes the tick with `sigprocmask`
  (mruby-task `ports/posix/task_hal.c`), which only masks the calling thread.
  `setitimer` SIGALRM is process-directed, so a tick that lands on another
  thread runs `mrb_tick` and relinks the task lists while the main thread is
  inside its "excluded" section.
- picoruby-ble's darwin port also calls `BLE_heartbeat()` from a GCD global
  queue timer every second (`ports/darwin/ble.c:32-41`, commit `8cd0bbac`),
  which calls `mrb_task_queue_push` off the VM thread. `task.h` forbids that.
  It returns early once 16 events are pending, which is why the 15 s window
  saw none.

Not yet proven: which of the two cross-thread paths broke the list, and what
the two off-main threads are. The next dtrace (needs the owner's sudo) is
`/tmp/stackchan-picoruby-debug/queue_push.d` (a copy is in the vault folder):
it prints the stack of every off-main `mrb_tick` and counts `BLE_heartbeat`
and `mrb_task_queue_push` per thread over 60 s. Run it with the main
thread's id as `$1`.

Both paths live in forks (picoruby / port-darwin, R2P2-darwin). Changing them
needs a pull request, the same as picoruby itself. The owner closes the
port-darwin session; do not hand this to it.

Once the daemon no longer freezes: one more `acceptance:check` with the robot
on, the report committed on `verdict: pass`, then push (pins first) and the
owner's merge decision.

### 2. After the merge: the issues for the next session

- #20: the dRuby instruction violation. Every app action still sends text
  frames; only the CLI's `remote` uses dRuby.
- #19: the dRuby unification itself, with audio measured before it may keep a
  direct route. It also covers port-darwin `3f2dfa24` (`radio.rb` must read
  through `gatt_event_int16` / `gatt_event_value`) and Service Changed.
- #21: build the `-StackchanBatch` apps in the Simulator; Xcode 27 needs
  port-darwin `7681c4f4` or later; certificates are revoked; `devicectl_udid`
  and `platform_trees_test` are open.
- #22: host tests that imitate the robot, dRuby timings, audio distortion
  (stages listed in the issue), the stack headroom and `PICORB_TASK_STACK_SIZE`,
  the one-off pitch read failure, `FIRMWARE_INPUTS` (why `aot/README.md` still
  names `stackchan-device-trial`), and the revert guard having no test.
- #23: move `docs/superpowers/` to the vault.
- Older and still open: #4, #5, #6 and #8.

### 3. The daemon has no defence against a client hanging up

Any client that hangs up mid-call can kill the daemon: its PicoRuby VM cannot
trap SIGPIPE (`Signal.list` carries no `PIPE` and every `Signal.trap` form
raises `SystemStackError`), so a peer gone while the daemon writes to it takes
the process down, and launchd restarts it. Closing that means `SO_NOSIGPIPE`
or an ignored SIGPIPE in picoruby's socket layer, which is upstream work
rather than a change here.

### 4. The lineage that will not boot

`c-primitives-verified` and `stackchan-integration` in the R2P2-ESP32 fork
differ by exactly one line, the picoruby submodule pointer: `7258676`, which
boots, against `568b4b88`, the lineage rebased onto upstream master, which
overflows the 8 KB picoruby task stack during its own startup and boot-loops.
`7258676` itself starts its picoruby task with 248 B of the 8 KB left, so the rebased lineage
needs only a little more startup depth to cross the line.
Switching is a one-line bump once that is resolved. Land shared changes on
both. The NimBLE ESP32 port itself is not waiting on this. It is what the device
runs — the vendored tree carries `nimble_owner.c`, there is no btstack
component, and the sdkconfig fragment is `bt_nimble` — and every verb drives it
end to end. What the boot loop blocks is adopting that port rebased
onto upstream master. Its plan is in the vault under
`02_dev_docs/picoruby-ble-esp32-port/plans/`.

### 5. What the dependency guard does not reach

`--pins-only` checks pins and nothing else, so a rotted gem ref or an edited
vendored tree passes at push time and is caught only by a full run.
`reachable_from_github` answers from remote-tracking refs before fetching, so a
branch force-pushed away reads as published until CI's fresh clone disagrees.
And `STACKCHAN_DEPS_GUARD=off` is one string away for whoever finds the guard
inconvenient.

Branch protection is handled separately, and would cover main and master only.
The refs this build depends on are long-lived integration branches and tags,
which protection would not cover, so those stay detection-only.

## Known and deliberately left alone

- The device tasks expect esp-idf at `~/esp/esp-idf` unless `ESP_IDF_EXPORT`
  says otherwise. The version is pinned where a machine reads it —
  `espressif/idf:v5.4.2` in the firmware workflow — and the python venv is
  found by version rather than named.
