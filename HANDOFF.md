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
included. The Mac, an iPhone and an Apple Watch (worn, with the app in front)
have each driven the robot that way on hardware.

`rake test` and the CRuby host tests pass.

## Next

Nothing is waiting. Work that has not been started is in the issue tracker
(`gh issue list`).
