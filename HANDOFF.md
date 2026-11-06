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
`main` build follows are untouched, so `main`'s `acceptance/lock.yml` is still
the robot's firmware and the way back.

| Tree | Repository | Branch on this line |
|---|---|---|
| stackchan-picoruby | bash0C7/stackchan-picoruby | this branch |
| R2P2-ESP32 | bash0C7/R2P2-ESP32 | `claude/latest-deps` (picoruby/R2P2-ESP32 master + the external build config, BLE / I2S links, CoreS3 board) |
| picoruby (firmware) | bash0C7/picoruby | `claude/latest-deps-firmware` (picoruby/picoruby master + picoruby/picoruby#427 merged + disconnect, `Kernel#extern`, picoruby-i2s) |
| picoruby (Apple) | bash0C7/picoruby | `claude/latest-deps-darwin` (port-darwin with picoruby/picoruby master merged in) |
| R2P2-darwin | bash0C7/R2P2-darwin | `claude/latest-deps` |
| picoruby-ili9342 | bash0C7/picoruby-ili9342 | `claude/latest-deps` |
| picoruby-py32-io-expander | bash0C7/picoruby-py32-io-expander | `main` (unchanged) |
| picoruby-scservo | bash0C7/picoruby-scservo | `main` (unchanged) |
| picoruby-multicore | bash0C7/picoruby-multicore | `claude/latest-deps` |
| suppify | bash0C7/suppify | `claude/latest-deps` (main + spinel pin) |
| spinel | bash0C7/spinel | `claude/latest-deps` (matz/spinel master + lib/newlib) |

The firmware is `MRB_INT32` + `MRB_WORD_BOXING` + mruby-bigint, as upstream
builds 32-bit targets. The AOT kernels are `module StackchanAot`, generated
with suppify `--newlib --table multicore_kernels`, so the VM and core 1 each
have their own kernel instance.

Run in the Linux cloud session and passed: `rake test` (rigor + every picotest
suite), the same picotest suites on a 32-bit `MRB_INT32` word-boxing host VM,
`rake test:host`, `pc/stackchan` and `pc/sidecar`, the firmware build from
`rake r2p2:setup` / `rake r2p2:build`, `tools/aot/syntax_check_mcu.sh`, and the
suites of suppify, spinel (`make newlib-test`), picoruby-multicore,
picoruby-ili9342, picoruby-py32-io-expander and picoruby-scservo.
`rake r2p2:qemu_check` passes; a probe app run under the same QEMU gate called
both kernels on the VM and `ulaw_decode` on core 1 at once and read the
expected bytes back. QEMU does not cover the cold boot, I2C, LCD, servos,
speaker or the BLE radio.

## Next — on the Mac

Not run here, because they need the robot, the Mac or Xcode:

1. Firmware on the robot: `rake acceptance:deploy`, then `rake acceptance:check`
   in a TTY terminal with the owner at the robot. This writes the new
   `acceptance/results/` report; merge nothing before its verdict is `pass`.
2. Apple side: `rake vendor:r2p2_darwin:setup` (or re-fetch `vendor/R2P2-darwin`
   at `claude/latest-deps`), `rake pc:vm_build`, `rake pc:app_bundle`,
   `rake pc:up`, then `stackchan status`; `rake acceptance:darwin` when a
   signing certificate is at hand. Simulator: `/stackchan-apple-simulator`.

The flash path calls `idf.py -p <port> flash` and `idf.py -p <port> monitor`
directly; R2P2-ESP32's own `rake flash` now needs the esp_flash gem and is not
used.

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
whether the idle panic is gone is for the acceptance run above to show. Other
work that has not been started is in the issue tracker (`gh issue list`).
