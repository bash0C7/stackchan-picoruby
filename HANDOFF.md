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
- the pre-merge device check, `acceptance/`: one firmware deployed once
  (`acceptance:deploy`), the app sent on its own (`acceptance:app`), and the
  board checked without writing flash (`acceptance:check`)

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

The robot runs this firmware.

On the robot and the Mac, every function in scope works:

- pc:up, face, LED, servo with a position detail, and dRuby `remote servo` /
  `remote face`
- say, selftest, calibrate
- the robot releasing an idle Mac, and the Mac reconnecting on its next action
- a head touch reaching the Mac (`stackchan touch listen`)

Two controller defects surfaced on the robot and are fixed with host tests that
failed first:

- `1e057cd` refuses a connection whose discovery stopped before both CCCDs.
- `794dbda` keeps the daemon's tick and shutdown tasks alive. `Task.new`
  blocks run with `self` as `main`.

On the robot, the tick fix shows up as `hold over`, keepalives and `release
seen: yes`.

The iOS and watchOS apps reached the end of a launch-argument run in the
Simulator before that argument was renamed to `-StackchanBatch` (`8f6dd68`).
They have not been built since (#21).

`rake test` passes with rigor at `0 new`. `rake test:host` fails only
`platform_trees_test#test_r2p2_darwin_names_no_stackchan`, because of the
locked R2P2-darwin (#21).

## Next

### 1. Not mergeable yet: two blockers

CLAUDE.md allows the merge only once an acceptance report reads
`verdict: pass`. It also has to be pushable. Neither holds yet. The plan is in
the vault:
`02_dev_docs/stackchan-picoruby/plans/2026-09-30-mergeable-plan.md`.

**Blocker A: the acceptance rules cannot yield `pass`.**

The only report, `acceptance/results/20260929-093450` (uncommitted), reads
`fail`:

- It stops at the Mac A → Mac B hand-off. The owner judged that step not
  needed, and its check assumes the dead-tick behaviour.
- `touch listen` is incomplete, and the eye-and-ear questions are unanswered.
- The verdict requires an iPhone / Watch run on devices whose certificates are
  revoked. iPhone / Watch scope is the Simulator.
- `chat` runs against a STUB sidecar, which proves nothing about chat.
- `pc_vm` duplicates what `pc:up` already fails on.
- `say` reads a sentence long enough to be a nuisance.

These rules are fixed before the merge. Then one `acceptance:check FROM=pc:up`
runs with the owner at the robot, and the owner runs `acceptance:touch` and
`acceptance:answer` in Terminal.app, which needs a TTY. The functions
themselves were confirmed on the robot, as above.

**Blocker B: the push guard refuses every push of this branch.**

`tools/hooks/pre_push_guard.sh` runs `tools/test_must_fail_on_revert.rb`. It
replays each changed test against the merge base `510d08e`. A test for a file
this branch adds (e.g. `test-host/device_lock_test.rb` for `lib/device_lock.rb`)
cannot load there. The script counts that as "did not run" and exits 1
(`:103-107`), when not loading at all is the strongest form of failing on
revert.

Once both blockers are cleared:

1. Push this branch and the related branches in the table.
2. Merge PR #11 (the owner's decision).
3. Bring each related repo's branch to its `main`.
4. Point the Rakefile's `R2P2_ESP32_REF` / `R2P2_DARWIN_REF` and the build
   config's gem refs back at `main`.
5. Archive `bash0C7/picoruby-stackchan-protocol` on GitHub (nothing here refers
   to it).

### 2. After the merge: the issues for the next session

- #20: the dRuby instruction violation. dRuby was added as a second path.
  Every app action still sends text frames, and only the CLI's `remote` uses
  dRuby.
- #19: the dRuby unification itself. Mac, iPhone and Watch talk to the robot
  over PicoRuby dRuby over BLE only, with audio measured before it is allowed
  a direct route.
  - It also covers the port-darwin `3f2dfa24` update, where `radio.rb` must
    read through `gatt_event_int16` / `gatt_event_value`, and Service Changed.
- #21: build. Build and launch the `-StackchanBatch` apps in the Simulator.
  - Xcode 27 needs port-darwin `7681c4f4` or later.
  - The certificates are revoked.
  - `devicectl_udid` and `platform_trees_test` are also open.
- #22: what is left once blockers A and B are cleared:
  - host tests that imitate the robot or restate the code
  - dRuby timings for face, LED and subtitle, with an ACK check
  - the audio distortion
  - `FIRMWARE_INPUTS`, which includes `aot/README.md`; that is why that file
    still names the skill `stackchan-device-trial`
- #23: move `docs/superpowers/` to the vault.
- Older and still open: #4, #5, #6 and #8.

The picoruby-ble state both sessions share is in the vault:
`02_dev_docs/picoruby-ble-esp32-port/notes/2026-09-29-stackchan-alignment-status.md`.
The evidence for the hand-off failure is in
`02_dev_docs/stackchan-picoruby/review/2026-09-29-handoff-ack-timeout/`.

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
