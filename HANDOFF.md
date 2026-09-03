# HANDOFF

Where the work stands and what comes next. **Current state only.**

This file is rewritten in place, never appended to. It carries no history: a
reader arriving cold has no reference point for what a past state was, so
"previously" and "as of <date>" do not belong here. Durable knowledge does not
belong here either — see "Where things are written" at the bottom.

## Now

The robot works end to end with the drawing primitives and the mu-law decode in
C: cold boot, BLE link, faces, blink, LEDs, servos, head touch, and audio
playback.

| Piece | Revision |
|---|---|
| `stackchan-picoruby` | `main` @ `058d9a4`, pushed |
| firmware tree `vendor/R2P2-ESP32` | `c-primitives-verified` @ `2f18720` |
| picoruby submodule under it | `7258676` (on GitHub as `stackchan-integration-verified`) |
| LCD driver gem | `bash0C7/picoruby-ili9342` `main` @ `01a1a02` |
| speaker gem | `mrbgems/picoruby-aw88298` here, fetched from `main` by the build_config |

Face redraw is 0.16-0.21 s against a 0.18 s BLE floor, down from 0.42-0.67 s;
the README has the table. Speech is 8 kHz mu-law at gain 0.05 — nothing clips
digitally at any gain, so audible break-up is the 1 W speaker being overdriven.

Tests: picotest device 194 / pc 79 / shared 28 / led 39 / si12t 22 / aw88298 14,
skip 0, plus six CRuby host test files, 53 tests (ten of them omitted where plutil is absent).

The reproducibility guard works. `git push` runs `tools/check_deps_pushed.sh
--pins-only` through `tools/hooks/pre_push_guard.sh`, and a push whose pins would
not survive is refused with the reason on stderr. That was measured, not
inferred: the hook was watched firing on `git push`, on `git -C <dir> push` and
on an absolute-path git; a leaf submodule was pointed at a local directory and
the push was refused naming it; the remote was restored and the push went
through. `test-host/deps_guard_test.rb` builds git fixtures broken in each way
the guard has been wrong and asserts it says so, without touching the network.

Prevention is the Claude Code hook and nothing under it: a git `core.hooksPath`
layer was built and taken back out, because it has to be configured per clone
and Claude is what does the pushing here. `STACKCHAN_DEPS_GUARD=off` stands it
down, which the one push that publishes a pin needs.

The full run walks 19 pins, 6 refs, 5 gem clones and 30 branches across 21
repositories in six seconds. Detection is `.github/workflows/deps.yml`, which
runs the whole script from an empty runner on every push, on pull requests and
weekly; it resolves all 19 nested pins from nothing and answers "every
dependency is reachable from GitHub", which is the one judge local state cannot
fool.

**This tree builds on a machine that is not this Mac.** That was an assumption
and is now a measurement: `.github/workflows/firmware.yml` builds in
`espressif/idf:v5.4.2` — the version `git describe` reports in the esp-idf here
— from a fresh clone, and produces a 2.3 MB `R2P2-ESP32.bin` with 45% of the app
partition free. It then rebuilds the host VM and runs every suite: picotest 376
with no failures and no crashes, and the CRuby host tests with ten omissions,
which are the tests that reach plutil. It runs weekly and on demand, not per
push, because a full esp-idf build is tens of minutes.

Getting it green took nine runs and turned up one real defect, two portability
bugs in the guard's own fixtures, one undeclared platform dependency, one
missing package and one place where picotest hides the reason a suite died.
Reaching it also meant the Rakefile could no longer spell one machine's paths:
`ESP_IDF_EXPORT` and `ESP_PYTHON` take overrides, and the venv is found by
version rather than named — this machine has idf5.4_py3.9, py3.12 and py3.14,
and a string sort picks 3.9.

Nothing above says whether the robot moves. Only the bench says that, and
neither workflow flashes anything.

## Next

### 1. What the guard still does not reach

Branch protection is being handled separately. It would be main and master only,
and the refs this build depends on are mostly long-lived integration branches
(`c-primitives-verified`, `port-darwin`, `stackchan-integration`) and tags, which
protection would not cover anyway, and a development branch disappearing when its
pull request merges is correct behaviour. Those stay detection-only, which is
what the ref check already does.

Smaller, and known: `--pins-only` checks pins and nothing else, so a rotted gem
ref or an edited vendored tree passes at push time and is caught only by a full
run; `reachable_from_github` answers from remote-tracking refs before fetching,
so a branch force-pushed away on GitHub reads as published until CI's fresh clone
disagrees; and `STACKCHAN_DEPS_GUARD=off` is one string away for whoever finds
the guard inconvenient.

### 2. Subproject C, BLE reliability

The defects under "Known issues" in the README: no retry on an ACK timeout, the
~45 s first `<A:done>` after a long idle, and `Daemon#stop` never reaching its
reply. The daemon also died once with SIGPIPE right after a `selftest` and
launchd restarted it; seen once, so it is not in the README.

## Known and deliberately left alone

- The device tasks still expect esp-idf at `~/esp/esp-idf` unless
  `ESP_IDF_EXPORT` says otherwise. The version is pinned where a machine reads
  it — `espressif/idf:v5.4.2` in the firmware workflow — rather than only in
  prose, and the python venv is found by version instead of named.

## Standing arrangements

- The R2P2-ESP32 fork's two branches differ by exactly one thing, the picoruby
  submodule pointer: `c-primitives-verified` holds `7258676`, which boots;
  `stackchan-integration` (`c1c56d4`) holds `568b4b88`, the lineage rebased onto
  upstream master, which overflows the 8 KB picoruby task stack during its own
  startup — before any application runs — and boot-loops. Everything else is
  identical, so switching is a one-line bump once that is resolved. Keep it that
  way: land shared changes on both.
- PR #10 is a draft holding the pre-launchd daemon process-management work and
  the NimBLE port plan. Nothing about it has been reviewed; its own body says
  what to look at.
- Publishing a pin is itself a push, so the guard would block the one command
  that fixes it. Prefix that push with `STACKCHAN_DEPS_GUARD=off` and nothing
  else.

## Where things are written

Nothing that outlives the current task should be recorded in this file.

- `README.md` — what the robot is and does, how to set it up and run it,
  capabilities, known issues, the latency measurements, and how the guard works
- `CLAUDE.md` — how to work in this repo: build and deploy flow, the device
  skills, and the pitfalls worth knowing before touching hardware
- this file — only the sections above
