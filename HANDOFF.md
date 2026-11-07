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

This branch moves every dependency onto its newest upstream. Nothing here is
merged. Each repository carries the work on its own branch, and the refs the
`main` build follows are untouched, so `main`'s `acceptance/lock.yml` is the
way back.

| Tree | Repository | Branch on this line |
|---|---|---|
| stackchan-picoruby | bash0C7/stackchan-picoruby | this branch |
| R2P2-ESP32 | bash0C7/R2P2-ESP32 | `claude/latest-deps` (picoruby/R2P2-ESP32 master + the external build config, BLE / I2S links, CoreS3 board) |
| picoruby | bash0C7/picoruby | `claude/port-darwin-linear`, for the firmware and the Apple builds alike: picoruby/picoruby master, then picoruby/picoruby#427, port-darwin's darwin commits, and the firmware commits (disconnect, `Kernel#extern`, picoruby-i2s, boxing-safe helpers, one BLE pump per VM) in a straight line |
| R2P2-darwin | bash0C7/R2P2-darwin | `claude/latest-deps` (`PICORUBY_REF` is the picoruby branch above) |
| picoruby-ili9342 | bash0C7/picoruby-ili9342 | `claude/latest-deps` |
| picoruby-py32-io-expander | bash0C7/picoruby-py32-io-expander | `main` (unchanged) |
| picoruby-scservo | bash0C7/picoruby-scservo | `main` (unchanged) |
| picoruby-multicore | bash0C7/picoruby-multicore | `claude/latest-deps` |
| suppify | bash0C7/suppify | `newlib-runtime-pr-pin` |
| spinel | bash0C7/spinel | `newlib-runtime-pr` (the branch meant for a matz/spinel PR) |

The robot carries the firmware pinned in `acceptance/lock.yml`, flashed once by
`acceptance:deploy`, and the latest report in `acceptance/results/` is
`verdict: pass` with the owner at the robot. The Mac daemon, the iPhone app and
the Apple Watch app run this line's picoruby: the iPhone app ran its batch
against the robot under `rake acceptance:darwin`, and the owner drove the robot
from the watch app (face, LED, head sweep). In that `acceptance:darwin` run the
second hand-off back to the Mac found no advertiser within the Mac's scan; the
robot answered the Mac and the iPhone minutes later, and what kept it from
advertising then was not determined. The report keeps the check's verdict.

## Next

1. Merging this line into `main` is the owner's call, as is replacing
   bash0C7/picoruby `port-darwin` with `claude/port-darwin-linear` (a force
   push; `baseline/stackchan-20261107-darwin` keeps the current one).
2. spinel `newlib-runtime-pr` and suppify `newlib-runtime-pr-pin` are the
   branches the lock pins. Once they land upstream (matz/spinel, suppify
   `main`), move `aot/suppify.pin` and `acceptance/lock.yml` to those commits.

## Going back

1. Check out `main` (or the branch `baseline/stackchan-20261107`, the same
   commit). Every dependency also has a `baseline/stackchan-20261107` branch at
   the commit `main` pins (picoruby has `-firmware` and `-darwin`).
2. On the Mac, `rake acceptance:deploy`: it checks every tree out at the
   `acceptance/lock.yml` shas and flashes that firmware.
3. Apple side: `rake pc:vm_build` and `rake acceptance:darwin` with the same
   `lock.yml`'s `darwin` values.

## Other work

The robot panics now and then while it idles, and reboots (#31). This line
carries the picoruby/picoruby#427 port, whose heartbeat stays off the VM heap;
one acceptance run does not show whether the idle panic is gone. Other work
that has not been started is in the issue tracker (`gh issue list`).
