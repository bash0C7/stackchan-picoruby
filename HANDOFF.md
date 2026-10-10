# HANDOFF

Where the work stands and what comes next. **Current state only.**

Rewritten in place, never appended to. It carries no history: a reader arriving
cold has no reference point for a past state, so "previously" and "as of
<date>" do not belong here. Durable knowledge does not belong here either —
README.md is what the robot is and does, CLAUDE.md is how to work on it, specs
and plans live in `docs/superpowers/`, and reviews and evidence live in the
Obsidian vault under `02_dev_docs/stackchan-picoruby/review/`.

Branch names and commit ids are not written here. What a build runs is read
from where a machine reads it: `acceptance/lock.yml` for every sha, `Rakefile`
and `build_config/esp32-stackchan.rb` for the refs the build follows.

## Now

Everything is on `main`. The robot works, and every subsystem it has has been
driven on the hardware: cold boot, BLE link, faces, LEDs, servos on both axes,
head touch, audio, and selftest. Servo absolute positioning — the point of the
whole thing — lands where it is told.

The robot carries the firmware and app of the latest report in
`acceptance/results/`, and that report's verdict is `pass`: one check run
start to finish in a TTY, with the owner at the robot answering the
questions.

Everything between a controller and the robot is dRuby over BLE, audio
included; there is no second route and no first NUS pair. The design is
`docs/superpowers/specs/2026-10-10-druby-single-route-design.md`. What the
report's run showed on the robot: `torque`, `face`, `led`, `servo`,
`selftest`, `calibrate`, the `remote` verb, `servo health` (no read error,
status 0 on both servos), `say`, `chat` against the real sidecar, and the
robot releasing a quiet central with the next action reconnecting. The head
was not touched within the 30 s of that run; the touch path (the one-second
`touches` poll feeding `touch listen`) is the one an earlier run of the same
firmware passed, and the app change since did not touch it.

`rake test` and the CRuby host tests pass.

The iOS and watchOS apps have never driven the robot with this controller.
Two faults that stopped every action inside their VMs are fixed and seen
fixed in the Simulators, where `status` now answers through the bridge
(`/stackchan-apple-simulator`): actions were reached through
`method_missing`, which the bridge's `__send__` runs as a C call that
starves the BLE pump, and the central used `method(:name)`, which those VMs
do not have. A Simulator has no Bluetooth, so nothing past `status` has run.

`rake test` runs `rigor:check` first, a host-side type analysis that fails on
any diagnostic absent from `rigor.baseline.json`. It needs `rake vendor:setup`
to have run, and installs its own gemset into `vendor/rigor-tool` on first use.
`docs/rigor.md` is the reference. `deps.yml` runs on every push; `firmware.yml`
runs weekly and on demand, so trigger it with `gh workflow run firmware.yml`
after changing anything it covers.

## Next

### A. The iPhone and the Watch against the robot

Blocked on signing, which only the owner can clear: Xcode has no Apple ID
(`No Accounts`), every Apple Development certificate in the keychain is
revoked, and the provisioning profile does not include the iPhone on USB.
With an account signed in under Xcode's Settings → Accounts, the build
registers the device and makes the certificate itself.

Then: `rake ios:device:lib ios:gen ios:device:build`, and
`ios:device:run` with `APP_CONSOLE=1` and
`APP_LAUNCH_ARGS='-StackchanBatch "connect;face joy;selftest;speak_audio <hex>"'`
while the Mac leaves the robot alone (no action for `c.hold` plus the
robot's `release_after`). `speak_audio` takes μ-law as hex; the Mac's
sidecar synthesises it (`synthesize(text, nil, nil)` on
`druby://127.0.0.1:8788`). The same for `watchos:` once a Watch is
reachable; the one paired with this Mac shows as unavailable. This is the
first time waits inside an action run on those VMs against a real link, so
read a timeout there as a finding about the VM's scheduler, not the robot.

### B. Things found on the way, not yet acted on

- `DRbBle::Responder#reply` calls the front with `send`. For a method the
  front defines that is direct, but a `bot.remote` handler is reached through
  `method_missing`, so on the robot it would run inside a nested VM and cost
  about 3 KB of the 8 KB task stack. `apps/robot/app.rb` declares no such
  handler today.
- `Daemon::CONNECTED_LINE` still reads `Connected; RX value_handle bound`, a
  handle that no longer exists. The Swift views of both apps, the darwin
  acceptance step and four tests match on that exact string, so changing it
  is one edit across all of them.
- R2P2-darwin's own watchOS build_config still lists `hal-io-darwin`, which
  no longer satisfies mruby's HAL provider contract at the picoruby this
  project pins, so its watchOS build should fail the same way this
  repository's did. That is R2P2-darwin's and the picoruby fork's to fix.

Why the daemon froze in the previous report, what closed it, and what is
still unexplained are in the vault: `review/2026-10-01-daemon-freeze/`,
`plans/2026-10-03-daemon-tick-thread.md` and
`review/2026-10-10-pr11-closing-notes.md`.

### Open issues

- #19: done and passed on the robot from the Mac; what is left of it is the
  iPhone and Watch run (A).
- #22: what is left needs the robot or a decision. The pitch position read
  that failed three times in a row once: the ESP32 receive path is ruled out
  by source (vault `review/2026-10-03-pitch-read-pos/`), and `servo health`
  now tells a silent servo from a bad reply the next time it happens. The
  stack headroom and `PICORB_TASK_STACK_SIZE` are a design decision
  (CLAUDE.md). Discovery time is recorded as `connect ms`.
- #24: LCD touch.
- The holes closed in the Mac VM are also in mruby's POSIX task HAL and in
  upstream picoruby-socket / picoruby-drb. That is upstream PR material.

### Adopting upstream picoruby for the firmware

The firmware's picoruby line, rebased onto upstream master, overflows the 8 KB
picoruby task stack during its own startup and boot-loops on the CoreS3. The
line in use leaves the picoruby task only a few hundred bytes at startup, so
the rebased one needs just a little more depth to cross the line. Raising
`PICORB_TASK_STACK_SIZE` is a design decision, not a tweak (CLAUDE.md).

The NimBLE ESP32 port itself is not waiting on this; it is what the device
runs. What the boot loop blocks is adopting that port as upstream carries it.
Its plan is in the vault under `02_dev_docs/picoruby-ble-esp32-port/plans/`.

### What the dependency guard does not reach

`--pins-only` checks pins and nothing else, so a rotted gem ref or an edited
vendored tree passes at push time and is caught only by a full run.
`reachable_from_github` answers from remote-tracking refs before fetching, so a
branch force-pushed away reads as published until CI's fresh clone disagrees.
And `STACKCHAN_DEPS_GUARD=off` is one string away for whoever finds the guard
inconvenient.

Branch protection is handled separately, and would cover default branches
only. The refs this build depends on in the two forks are long-lived
integration branches, which protection would not cover, so those stay
detection-only.

## Known and deliberately left alone

- The device tasks expect esp-idf at `~/esp/esp-idf` unless `ESP_IDF_EXPORT`
  says otherwise. The version is pinned where a machine reads it — the image
  tag in the firmware workflow — and the python venv is found by version rather
  than named.
