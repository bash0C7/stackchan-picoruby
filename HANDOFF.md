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
| `stackchan-picoruby` | `main`, the only branch, in sync with origin |
| firmware tree `vendor/R2P2-ESP32` | `c-primitives-verified` @ `2f18720` |
| picoruby submodule under it | `7258676` |
| LCD driver gem | `bash0C7/picoruby-ili9342` `main` @ `01a1a02` |
| speaker gem | `mrbgems/picoruby-aw88298` here, fetched from `main` by the build_config |

The device reports App version `2f18720`, so it is running this tree.

Tests pass: 379 picotest across device, pc, shared and the three driver gems,
with no failures, crashes or skips, plus the CRuby host tests, where ten cases
are omitted on machines without `plutil`. Both workflows are green on the tip
of `main`. `deps.yml` runs on every push; `firmware.yml` runs weekly and on
demand, so trigger it with `gh workflow run firmware.yml` after changing
anything it covers.

## Next

### 1. BLE reliability

The README's Known issues, in the order they are worth attacking:

- An ACK timeout is not retried. `ble_client.rb` raises `TimeoutError` and the
  CLI command fails; a dropped frame is never resent.
- `Daemon#start` primes the sidecar between opening the drb port and announcing
  itself, so a sidecar connect that hangs freezes the daemon VM with the port
  already open, and `rake pc:up` reports a daemon that listens but will not
  answer. Running `rake pc:up` again clears it.
- `<A:done>` can take about 45 s on the first `say` after a long idle. This is
  untested rather than doubtful: a `say` on a freshly booted device answers in
  seconds, which is not the ten-hour-idle condition the entry describes.
  Recreating that condition is what would settle it.
- A daemon SIGPIPE was seen once right after a `selftest`, with launchd
  restarting it. It has not recurred.

### 2. The lineage that will not boot

`c-primitives-verified` and `stackchan-integration` in the R2P2-ESP32 fork
differ by exactly one line, the picoruby submodule pointer: `7258676`, which
boots, against `568b4b88`, the lineage rebased onto upstream master, which
overflows the 8 KB picoruby task stack during its own startup and boot-loops.
Switching is a one-line bump once that is resolved. Land shared changes on
both. This boot loop is also what stands between the picoruby-ble ESP32 NimBLE
port and its hardware end-to-end test; that port's plan is in the vault under
`02_dev_docs/picoruby-ble-esp32-port/plans/`.

### 3. What the dependency guard does not reach

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
