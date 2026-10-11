# HANDOFF

What the next session needs to pick the work up. **Current state only.**

Rewritten in place, never appended to. It carries no history: a reader arriving
cold has no reference point for a past state, so "previously" and "as of
<date>" do not belong here. Nothing durable belongs here either — README.md is
what the robot is and does, CLAUDE.md is how to work on it and what has been
measured, work that is not started is an issue, specs and plans live in
`docs/superpowers/`, and reviews and evidence live in the Obsidian vault under
`02_dev_docs/stackchan-picoruby/review/`.

Branch names and commit ids are not written here. What a build runs is read
from where a machine reads it: `acceptance/lock.yml` for every sha, `Rakefile`
and `build_config/esp32-stackchan.rb` for the refs the build follows.

## Now

Everything is on `main` and pushed. Nothing is in progress.

The robot carries the firmware pinned in `acceptance/lock.yml` and the app of
the latest report in `acceptance/results/`, whose verdict is `pass`. That
report holds one full check from the Mac with the owner at the robot, and a
`rake acceptance:darwin` run in which the iPhone drove the robot with nobody
touching it.

Everything between a controller and the robot is dRuby over BLE, audio
included. The Mac and the iPhone run the Apple line pinned in
`acceptance/lock.yml`. The Apple Watch carries an app built before that pin;
`rake watchos:device:all` puts the current one on it.

`rake test` and the CRuby host tests pass.

## Next

The robot panics now and then while it idles, and reboots (#31). The BLE port
of the picoruby line the firmware is built from pushes its heartbeat into the
VM from the timer task; the ESP32 port under picoruby/picoruby#427 does not.
Moving the firmware onto that port is a firmware change: a flash and a new
acceptance report. What such a line has to keep so that it boots is in
`CLAUDE.md` ("picoruby-ble の lineage を乗り換える時") and #30. Until then a
`rake acceptance:darwin` run fails at the hand-off when the robot reboots
under it; the robot takes about 15 s from reset to advertising.

Other work that has not been started is in the issue tracker
(`gh issue list`).
