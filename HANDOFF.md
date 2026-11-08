# HANDOFF

What the next session needs to pick the work up. **Current state only.**

Rewritten in place, never appended to. It carries no history: a reader arriving
cold has no reference point for a past state, so "previously" and "as of
<date>" do not belong here. Nothing durable belongs here either — README.md is
what the robot is and does, CLAUDE.md is how to work on it and what has been
measured, work that is not started is an issue, specs and plans live in
`docs/superpowers/`, and reviews and evidence live in the Obsidian vault under
`02_dev_docs/stackchan-picoruby/review/`.

What a build runs is read from where a machine reads it: `acceptance/lock.yml`
for every sha, `Rakefile` and `build_config/esp32-stackchan.rb` for the refs
the build follows.

## Now

`main` carries every dependency on its newest upstream. The dependencies'
work stays on their own branches, not yet merged into those repositories'
`main`:

| Tree | Repository | Branch `main` builds from |
|---|---|---|
| R2P2-ESP32 | bash0C7/R2P2-ESP32 | `claude/latest-deps` (picoruby/R2P2-ESP32 master + the external build config, BLE / I2S links, CoreS3 board) |
| picoruby | bash0C7/picoruby | `claude/port-darwin-linear`, for the firmware and the Apple builds alike: picoruby/picoruby master, then picoruby/picoruby#427, port-darwin's darwin commits, and the firmware commits (disconnect, `Kernel#extern`, picoruby-i2s, boxing-safe helpers, one BLE pump per VM) in a straight line. `port-darwin` has it merged and holds the same tree |
| R2P2-darwin | bash0C7/R2P2-darwin | `claude/latest-deps` (`PICORUBY_REF` is the picoruby branch above) |
| picoruby-ili9342 | bash0C7/picoruby-ili9342 | `claude/latest-deps` |
| picoruby-py32-io-expander | bash0C7/picoruby-py32-io-expander | `main` (unchanged) |
| picoruby-scservo | bash0C7/picoruby-scservo | `main` (unchanged) |
| picoruby-multicore | bash0C7/picoruby-multicore | `claude/latest-deps` |
| picoruby-foundation-model | bash0C7/picoruby-foundation-model | `claude/session` (adds `FoundationModel::Session` and the timeout; the Mac VM only) |
| suppify | bash0C7/suppify | `newlib-runtime-pr-pin` |
| spinel | bash0C7/spinel | the commit suppify's `spinel.pin` names; `newlib-runtime-pr` has since been rebuilt on a newer matz/spinel master, so that commit is no longer on the branch |

The robot carries the firmware pinned in `acceptance/lock.yml`, flashed once by
`acceptance:deploy`, and the latest report in `acceptance/results/` is
`verdict: pass` with the owner at the robot. The Mac daemon, the iPhone app and
the Apple Watch app run this line's picoruby: the iPhone app ran its batch
against the robot under `rake acceptance:darwin`, and the owner drove the robot
from the watch app (face, LED, head sweep).

The AOT pins stay at the commits the robot passed with. They move at the next
firmware rebuild, when the owner asks for it. `tools/aot/setup.sh` fetches
spinel by sha; the suppify session measured that a fetch by that sha works and
a clone followed by a checkout of it does not.

This Mac holds every tree at those pins and built: `vendor/R2P2-ESP32`
(`r2p2:setup` done), `vendor/R2P2-darwin` with its picoruby refreshed,
`build/aot` (suppify and spinel built, kernels generated), the host picotest
VM, the Mac VM and `~/Applications/StackchanPico.app` (the daemon runs from
`rake pc:up`). Work that needs none of them changed can start from here.

## Next

The branch `claude/picoruby-only` leaves CRuby only where rake runs: the
sidecar and the `tools/*.rb` scripts run on the Mac VM, and the revert guard
and the AOT build run inside rake. It and picoruby-foundation-model's
`claude/session` are on GitHub. The Mac VM in `~/Applications/StackchanPico.app`
carries the gem (`acceptance/lock.yml` `darwin.repos` sha), and launchd runs
the real sidecar on it now (`pc:up ALLOW_BUSY=1`; the robot was off).

Left before the branch can merge:

1. With the robot on: `bin/stackchan chat こんにちは` and `bin/stackchan say …`
   through the PicoRuby sidecar (the owner listens), then one
   `acceptance:check` run to `verdict: pass`. The firmware does not change,
   so nothing is flashed.
2. Move `docs/superpowers/plans/2026-11-08-cruby-only-for-rake.md` to the vault.

## Going back

1. Check out the branch `baseline/stackchan-20261107`. Every dependency also
   has a `baseline/stackchan-20261107` branch at the commit that baseline pins
   (picoruby has `-firmware` and `-darwin`).
2. On the Mac, `rake acceptance:deploy`: it checks every tree out at the
   `acceptance/lock.yml` shas and flashes that firmware.
3. Apple side: `rake pc:vm_build` and `rake acceptance:darwin` with the same
   `lock.yml`'s `darwin` values.

## Other work

The robot panics now and then while it idles, and reboots (#31). This line
carries the picoruby/picoruby#427 port, whose heartbeat stays off the VM heap;
one acceptance run does not show whether the idle panic is gone. Other work
that has not been started is in the issue tracker (`gh issue list`).
