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

1. spinel `newlib-runtime-pr` and suppify `newlib-runtime-pr-pin` are the
   branches the lock pins. Once they land upstream (matz/spinel, suppify
   `main`), move `aot/suppify.pin` and `acceptance/lock.yml` to those commits.

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
