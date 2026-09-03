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
| `stackchan-picoruby` | `main`, **not yet on `origin/main`, which is still at `03f8ee4`** |
| firmware tree `vendor/R2P2-ESP32` | `c-primitives-verified` @ `2f18720` |
| picoruby submodule under it | `7258676` (on GitHub as `stackchan-integration-verified`) |
| LCD driver gem | `bash0C7/picoruby-ili9342` `main` @ `01a1a02` |
| speaker gem | `mrbgems/picoruby-aw88298` here, fetched from `main` by the build_config |

Face redraw is 0.16-0.21 s against a 0.18 s BLE floor, down from 0.42-0.67 s;
the README has the table. Speech is 8 kHz mu-law at gain 0.05 — nothing clips
digitally at any gain, so audible break-up is the 1 W speaker being overdriven.

Tests: picotest device 194 / pc 79 / shared 28 / led 39 / si12t 22 / aw88298 14,
skip 0, plus six CRuby host files, 51 tests.

The reproducibility guard works. `git push` runs `tools/check_deps_pushed.sh
--pins-only` through `tools/hooks/pre_push_guard.sh`, and a push whose pins would
not survive is refused with the reason on stderr. That was measured, not
inferred: the hook was watched firing on `git push`, on `git -C <dir> push` and
on an absolute-path git; a leaf submodule was pointed at a local directory and
the push was refused naming it; the remote was restored and the push went
through. `test-host/deps_guard_test.rb` builds git fixtures broken in each way
the guard has been wrong and asserts it says so, without touching the network.

The full run walks 19 pins, 6 refs, 5 gem clones and 30 branches across 21
repositories in six seconds, and it is red right now for two true reasons: main
is unpushed, and the `build/repos` clone of this repo is at `b743d62` while
`main` is at `03f8ee4`, so a firmware build would compile that older aw88298.
The subtree happens to be identical, so nothing is wrong on the device; clearing
the clone is what makes the next build match its own configuration.

## Next

### 1. Push, then let CI say whether it holds up

Nothing above is on GitHub yet. `.github/workflows/deps.yml` runs the same
script from an empty runner, which is the only part of the guard that has not
been exercised against the new code — a fresh clone with every nested submodule
resolved is too large to reproduce here. Everything it depends on was checked
locally instead: both ref extractions from the Rakefile return the right values,
both refs exist on GitHub, all 20 submodule URLs name github.com, and a depth-1
clone gives the `refs/remotes/origin/<branch>` the unpushed-commit check reads.

### 2. Prevention still has one path, not all of them

The guard runs from a Claude Code hook, so it sees pushes made through the Bash
tool and nothing else — not a terminal, not an IDE, not a rake task that pushes.
Moving that layer down to git itself would cover them: a `pre-push` committed
under `.githooks/`, with `rake vendor:setup` pointing `core.hooksPath` at it in
this checkout and in the vendored trees, since those are where the pushes that
matter happen. It stays one `git config` per clone away from automatic, which is
the honest ceiling.

Branch protection is settled and small: **main and master only.** The refs this
build depends on are mostly long-lived integration branches
(`c-primitives-verified`, `port-darwin`, `stackchan-integration`) and tags, which
protection would not cover anyway, and a development branch disappearing when its
pull request merges is correct behaviour. So those stay detection-only, which is
what the ref check already does. Nothing is applied on GitHub yet.

Smaller, and known: `--pins-only` checks pins and nothing else, so a rotted gem
ref or an edited vendored tree passes at push time and is caught only by a full
run; `reachable_from_github` answers from remote-tracking refs before fetching,
so a branch force-pushed away on GitHub reads as published until CI's fresh clone
disagrees; and `STACKCHAN_DEPS_GUARD=off` is one string away for whoever finds
the guard inconvenient.

### 3. Subproject C, BLE reliability

The defects under "Known issues" in the README: no retry on an ACK timeout, the
~45 s first `<A:done>` after a long idle, and `Daemon#stop` never reaching its
reply. The daemon also died once with SIGPIPE right after a `selftest` and
launchd restarted it; seen once, so it is not in the README.

## Known and deliberately left alone

- Both picoruby checkouts carry `mrbgems/picoruby-mruby/lib/estalloc` and
  `mrbgems/picoruby-r2p2/lib/pico-extras` as untracked directories, left from
  branches where those paths were submodules. At the pinned commit
  `picoruby-machine/mrbgem.rake` reads `lib/estalloc` out of its own gem
  directory and nothing reads either stray, so they change no build. The guard
  names them on every full run. Deleting inside a vendored tree is destructive
  and buys only tidiness, so it waits for a decision.
- `Rakefile` spells one esp-idf python venv,
  `~/.espressif/python_env/idf5.4_py3.14_env/bin/python`, and the toolchain
  itself (esp-idf v5.4 at `~/esp/esp-idf`) is pinned in prose. Another machine
  installing a different Python gets a different directory name and the device
  tasks fail on it. Making the path discovered rather than spelled cannot be
  verified without a firmware build, so it is untouched.

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
