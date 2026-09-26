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

Tests pass: 468 picotest across device, pc, shared, drb-ble and the three driver gems,
with no failures, crashes or skips, plus the CRuby host tests, where ten cases
are omitted on machines without `plutil`. Both workflows are green on the tip
of `main`.

`rake test` now runs `rigor:check` first, a host-side type analysis that fails
on any diagnostic absent from `rigor.baseline.json`. It needs `rake vendor:setup`
to have run, and installs its own gemset into `vendor/rigor-tool` on first use.
Seventeen diagnostics are frozen in the snapshot; eight of them are false
positives from rigor 0.3.7 and the rest are stated invariants the code does not
declare. `docs/rigor.md` is the reference. `deps.yml` runs on every push; `firmware.yml` runs weekly and on
demand, so trigger it with `gh workflow run firmware.yml` after changing
anything it covers.

## Next

### 1. Put dRuby over BLE, the AOT kernels and core 1 on the device

The branch `claude/ecstatic-allen-s6qki1` carries three pieces that are
green on the host and built into firmware, but have not run on the robot:

- **dRuby over BLE** — `mrbgems/picoruby-drb-ble`, a second characteristic
  pair next to NUS carrying the DRb stream, `StackchanApp::Remote` as the
  front, `stackchan remote <method>` on the Mac. R2P2-darwin
  `claude/drb-over-ble` sends the iOS / watchOS apps' commands the same way.
- **AOT kernels** — `aot/`: mu-law decode and glyph expansion written in Ruby
  and compiled with spinel → suppify. `picoruby-aw88298` is pure Ruby now;
  picoruby-ili9342 `claude/aot-glyph16` hands 16-row glyphs to the kernel.
- **core 1** — picoruby-multicore runs `ulaw_decode` there while core 0
  writes the previous chunk to I2S.

R2P2-ESP32 `claude/stackchan-aot-multicore-drb` wires picoruby-drb, the
kernels and multicore into the firmware; `R2P2_ESP32_REF` defaults to it, so
an existing `vendor/R2P2-ESP32` has to be switched to that branch, and the
fetched ili9342 in `build/repos/` moved to `claude/aot-glyph16` (the cache is
not pulled). It builds with ESP-IDF v5.4.2: the app binary grows 148,240 B
(42% of the app partition still free) and DIRAM use goes from 150,415 to
164,295 of 341,760 B. suppify is pinned to its `claude/string-arg-length`
branch, which keeps 0x00 in String arguments and fixes the runtime-symbol
collision between two suppify libraries on Linux.

What only the device can answer:
- `rake r2p2:full_rebuild SRC=app/application.rb`, then the boot log: the
  line `[application] dRuby over BLE enabled`, and no panic from the 8 KB VM
  stack or the task watchdog on core 1.
- `ble_control_smoke` / `ble_servo_smoke` / `ble_torque_smoke`, then
  `stackchan remote servo YL=50 PU=30 T=500` — it must print the same detail
  line the text link gives.
- `say` with a clip long enough to span several 2046-byte chunks: no gap
  between chunks.
- Timings, as two points in one session: `ROUNDS=8 tools/face_profile.zsh`
  and a `<text:…>` subtitle before and after, and `say` receive-to-done.
  Host numbers (x86_64, `bench/`): glyph 16x16 44.9 → 8.5 µs; mu-law 4096 B
  interpreted ~1.9 ms → ~0.29 ms on the pthread multicore port.

Once it holds, merge in order: suppify, picoruby-ili9342, this repo (the
darwin build_configs fetch picoruby-drb-ble from `main`), R2P2-darwin, then
point R2P2-ESP32's ili9342 back at `main`.

### 2. The daemon has no defence against a client hanging up

`rake pc:up` failed about a quarter of the time with "daemon on 8787 is
listening but did not answer status". The cause is not a slow daemon. Its port
check connected to the drb port and closed immediately; the daemon, blocked in
its own startup and running cooperative Tasks, could not service that connection
until it unblocked, and then wrote to a socket whose peer was gone and died of
SIGPIPE. Measured at 4 failures in 15 bring-ups, and 0 in 15 once the check asks
the kernel who is listening instead of connecting.

What remains is the daemon side of it. Its PicoRuby VM cannot trap SIGPIPE --
`Signal.list` carries no `PIPE` and every `Signal.trap` form raises
`SystemStackError` -- so any client that hangs up mid-call can still kill it,
and launchd restarts it. Closing that means `SO_NOSIGPIPE` or an ignored SIGPIPE
in picoruby's socket layer, which is upstream work rather than a change here.

This also accounts for the SIGPIPE recorded as a one-off after a `selftest`. It
was never a one-off.

### 3. The lineage that will not boot

`c-primitives-verified` and `stackchan-integration` in the R2P2-ESP32 fork
differ by exactly one line, the picoruby submodule pointer: `7258676`, which
boots, against `568b4b88`, the lineage rebased onto upstream master, which
overflows the 8 KB picoruby task stack during its own startup and boot-loops.
Switching is a one-line bump once that is resolved. Land shared changes on
both. The NimBLE ESP32 port itself is not waiting on this. It is what the device
already runs — the vendored tree carries `nimble_owner.c`, there is no btstack
component, and the sdkconfig fragment is `bt_nimble` — and it was driven end to
end over every verb. What the boot loop blocks is adopting that port rebased
onto upstream master. Its plan is in the vault under
`02_dev_docs/picoruby-ble-esp32-port/plans/`.

### 4. What the dependency guard does not reach

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
