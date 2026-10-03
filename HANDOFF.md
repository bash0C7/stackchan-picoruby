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
| picoruby (fork, under R2P2-darwin) | `port-darwin` | `e2783d0`, pushed |
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
- The Mac VM is built from port-darwin `e2783d0` with `hal-task-darwin`: the
  scheduler tick runs on the VM thread only (see Next 1).

### The last acceptance run

Every step through the questions passed: stack high-water `888 B free`, the
five answers all `y` (the owner heard no distortion). It stopped at
`torque off` because the Mac daemon froze; `chat` has not run against the real
sidecar yet. Two earlier runs failed on one-offs recorded in #22: a pitch
`read_pos` that failed three times, and the daemon dying of SIGPIPE.

## Next

### 1. The Mac daemon freeze: both writers closed, the fix awaits the owner's dtrace

The robot is powered off. Evidence is in the vault:
`02_dev_docs/stackchan-picoruby/review/2026-10-01-daemon-freeze/`; the plan
and its adversarial review are `plans/2026-10-03-daemon-tick-thread.md`.

What froze: the mruby-task waiting list became cyclic. Daemon 55951 spent
all 501 `spindump` samples walking `q_waiting_` in `queue_wake_one_waiter`
(`mrb_task_queue_push`) at 99.8 % CPU; daemon 15112 sat at 0 % with every
task asleep. The heap was never the cause (about 750 KB of 6.4 MB, flat).

Why: two paths wrote the task lists from threads other than the VM thread.

- `mrb_tick` (mruby-task `task.c`) relinks waiting → ready. The POSIX HAL
  arms `setitimer`, whose SIGALRM is process-directed; Darwin delivers it to
  any thread not blocking it, and CoreBluetooth's GCD threads never block it.
  The exclusion `mrb_task_disable_irq` is `sigprocmask`, which masks only the
  calling thread. dtrace over 15 s saw 3 of 3,739 ticks on two non-main
  threads (`dtrace-queue-push-15s.txt`; that output is from an earlier
  version of the saved script, so it has no stacks for those ticks; the only
  caller of `mrb_tick` in this build is the signal handler).
- picoruby-ble's darwin port at pin `97479c96` called `BLE_heartbeat()` →
  `mrb_task_queue_push` from a GCD timer every second.

What is done (all local, nothing pushed):

- port-darwin `23e5bb89` (origin) fixes the heartbeat: the timer sets a flag,
  `ble_scheduler_pump` turns it into `BLE_heartbeat()` on the VM thread.
- port-darwin `e2783d0` (fork clone `~/dev/src/github.com/bash0C7/picoruby`,
  worktree `picoruby-port-darwin`) adds `mrbgems/hal-task-darwin`, an external
  HAL gem (same mechanism as `hal-io-darwin`) that replaces mruby-task's
  POSIX HAL with the same code plus one check: a handler on any thread other
  than the VM thread re-sends SIGALRM to the VM thread with `pthread_kill`.
  `build_config/darwin-stackchan-pc.rb` includes it; `acceptance/lock.yml`
  pins it. `vendor/R2P2-darwin/vendor/picoruby` was refreshed from the local
  clone (`PICORUBY_REPO=… PICORUBY_REF=port-darwin rake refresh`).
- The VM built, `libmruby.a` carries one `task_hal.o`, a Task::Queue and
  `sleep_ms` timing script matches the previous binary, and the daemon is up
  under launchd from the rebuilt bundle (`status` answers `busy`, robot off).
- QEMU gate on the firmware tree: PASS (`qemu-20261003-001117.log`).

What the measurements after the fix say (vault folder, `tick_threads-*.out`
and `tick-race-tests-README.md`):

- dtrace 60 s idle and 60 s while `stackchan connect` kept CoreBluetooth
  scanning: `sigalrm_handler`, `mrb_tick` and `mrb_task_queue_push` all on
  one thread (14,949 / 14,862 ticks). The forwarding path never ran.
- Why those 3 ticks ran off-main is **not established**. The candidate
  mechanism comes from XNU `get_signalthread` on the apple-oss-distributions
  `main` branch: a process-directed signal goes to the first thread in
  `p_uthlist` that does not have it masked (pthreads first, workqueue threads
  second), which would send the tick to a CoreBluetooth or dispatch thread
  exactly while the VM thread masks SIGALRM inside `mrb_task_disable_irq`.
  Standalone C tests on this Mac (`tick-race-tests-README.md`) did not show
  that redirection. This Mac runs xnu-13432 (macOS 27.0); the newest published XNU is
  xnu-12377 (macOS 26), so the source of this kernel's thread selection cannot
  be read. Neither the published source nor the tests settle it. The forwarding handler closes the path whatever the
  trigger is, but that is containment, not explanation.

What the port-darwin refresh changed for the controller (read against the
diff `97479c96..e2783d02`):

- GATT events now carry the BTstack 1.6 layout (payload at offset 8).
  `radio.rb` read notifications at the old offsets and would have turned
  every reply from the robot into handle 0 with an empty value; `de6be64`
  reads them through `gatt_event_int16` / `gatt_event_value`, and the pc
  suite's packets and BLE stub follow the same layout.
- `connect` must be called from `advertising_report_callback` during a
  scan (it is), `scan`'s keyword arguments and `_event_popped` are
  unchanged, the controller matches characteristics by `uuid128` so the
  changed `uuid128_to_uuid32` byte order does not reach it, and the CCCD
  write and disconnect packets are unchanged. CoreBluetooth events are now
  pumped at scheduler entry, so with one busy task they arrive within a
  timeslice (12 ms); the controller's wait loops `sleep_ms` between polls.

What is not done:

- The fork commit `e2783d0` is pushed (`origin/port-darwin`). This branch is
  not. The same hole is in mruby's POSIX HAL (upstream PR material).
- Nothing above has met the robot: the rebuilt VM has only reached `busy`
  with the robot off. A real link through the refreshed darwin port (scan,
  discovery, CCCD, notification, dRuby) is unverified.
- Two known one-offs are untouched and can still stop a run: the daemon dies
  on SIGPIPE (Next 3) and the pitch `read_pos` that failed three times (#22).
- Then one more `acceptance:check` with the robot on, the report committed on
  `verdict: pass`, push (pins first) and the owner's merge decision.

### 2. After the merge: the issues for the next session

- #20: the dRuby instruction violation. Every app action still sends text
  frames; only the CLI's `remote` uses dRuby.
- #19: the dRuby unification itself, with audio measured before it may keep a
  direct route. It also covers Service Changed.
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
