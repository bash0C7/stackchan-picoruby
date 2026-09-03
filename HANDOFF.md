# HANDOFF

Where the work stands and what comes next. **Current state only.**

This file is rewritten in place, never appended to. It carries no history: a
reader arriving cold has no reference point for what a past state was, so
"previously" and "as of <date>" do not belong here. Durable knowledge does not
belong here either — see "Where things are written" at the bottom.

## Now

The robot works end to end with the drawing primitives and the mu-law decode in
C: cold boot, BLE link, faces, blink, LEDs, servos, head touch, and audio
playback. Both pull requests that produced it are merged.

| Piece | Revision |
|---|---|
| `stackchan-picoruby` | `main` @ `72acd8b` |
| firmware tree `vendor/R2P2-ESP32` | `c-primitives-verified` @ `2f18720` |
| picoruby submodule under it | `7258676` (on GitHub as `stackchan-integration-verified`) |
| LCD driver gem | `bash0C7/picoruby-ili9342` `main` @ `01a1a02` |
| speaker gem | `mrbgems/picoruby-aw88298` here, fetched from `main` by the build_config |

Face redraw is 0.16-0.21 s against a 0.18 s BLE floor, down from 0.42-0.67 s;
the README has the table. Speech is 8 kHz mu-law at gain 0.05 — nothing clips
digitally at any gain, so audible break-up is the 1 W speaker being overdriven.
The faces and LEDs have been looked at and render as they did before.

Tests: picotest device 194 / pc 79 / shared 28 / led 39 / si12t 22 / aw88298 14,
skip 0, plus five CRuby host files.

A fresh clone of the firmware tree resolves all 19 nested submodules; that was
measured, not assumed.

## Next

### 1. The reproducibility guard does not work. Fix it first.

`tools/check_deps_pushed.sh`, `.claude/settings.json` and
`.github/workflows/deps.yml` were added to stop a dependency from existing only
on one disk. Reviewed afterwards, and four defects are confirmed by measurement
on this machine. **Prevention currently does nothing at all.** Fix in this
order:

1. **The push hook never fires.** `matcher` matches the tool *name* only, and a
   value containing `(`, `)` or `*` becomes an unanchored regex tested against
   the literal string `Bash` — so `"Bash(git push*)"` can never match. Command
   filtering belongs in a separate `if` field on the hook handler
   (`"if": "Bash(git *)"`). Confirmed against code.claude.com/docs/en/hooks and
   by a `git push --dry-run` that produced no hook output. Note also that `if`
   matching is per-subcommand against its own argv, so `git -C <dir> push` does
   not prefix-match a `git push*` pattern — the pushes that matter here take
   that form.
2. **A local path is misclassified as GitHub.** `github_remotes` matches the
   substring `github.com` anywhere in the URL, and clones on this machine live
   under `~/dev/src/github.com/...`. Three of the four remotes on the picoruby
   submodule are local directories and all three are treated as proof of
   publication. Match the host, not the substring.
3. **The documented setup cannot produce the Mac-side VM.**
   `vendor:r2p2_darwin:setup` clones R2P2-darwin only; the `vendor/picoruby`
   that `pc:vm_build` needs comes from R2P2-darwin's *own* `rake setup` (a plain
   recursive clone, not a submodule), which nothing here invokes. CI never
   creates it either, so the check skips it silently — and a check that skips is
   a check that passes.
4. **Nested submodule pins are invisible.** `ls-tree -r` stops at each gitlink,
   so one pin is checked and the ten inside picoruby are not — including
   `mrbgems/picoruby-mruby/lib/mruby`, which CLAUDE.md names as a drift point.

Lower down, from the same review, unverified here: `$CLAUDE_PROJECT_DIR` does
not follow into a worktree, so a push from `.worktrees/` validates the main
checkout instead; the gem-ref `sed` needs `github:` first on the same physical
line; no `pipefail`, so an uninitialised `vendor/R2P2-ESP32` passes the pin
section vacuously; `pc/stackchan/Gemfile`'s git-sourced gem is outside the
model; aw88298 is fetched from `main` while you work on a branch, so the tree
and the firmware can disagree unnoticed; the toolchain pins live in prose and
`ESP_PYTHON` hardcodes one venv; CI resolves refs but cannot build, so
build_config and API drift pass it.

### 2. Subproject C, BLE reliability

The defects under "Known issues" in the README: no retry on an ACK timeout, the
~45 s first `<A:done>` after a long idle, and `Daemon#stop` never reaching its
reply. The daemon also died once with SIGPIPE right after a `selftest` and
launchd restarted it; seen once, so it is not in the README.

### Standing arrangements

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

## Where things are written

Nothing that outlives the current task should be recorded in this file.

- `README.md` — what the robot is and does, how to set it up and run it,
  capabilities, known issues, and the latency measurements
- `CLAUDE.md` — how to work in this repo: build and deploy flow, the device
  skills, and the pitfalls worth knowing before touching hardware
- this file — only the sections above
