# pc/stackchan-pico — PC side in PicoRuby

The launchd and process glue for the Mac-side StackChan controller, which runs
in PicoRuby so both ends (device firmware and PC) share one runtime. What the
Mac does is `apps/mac/app.rb` (`App = StackChan.controller do |c| … end`);
everything that file does not arrange is the controller engine in
`mrbgems/picoruby-stackchan-controller`. This directory holds only
`bin/stackchan`, `app/boot_daemon.rb`, `app/boot_cli.rb`,
`app/drb_eintr_retry.rb`, `app/fake_ble.rb` and the app bundle's plist.
`pc/stackchan` holds only the CRuby AI/voice sidecar support code: Apple
Foundation Model and macOS TTS stay in a CRuby sidecar bridged over dRuby.

## Architecture

```
stackchan <verb>           ← bin/stackchan (shell wrapper: exec only)
   │ attaches
   ▼
CLI (PicoRuby)  ──picoruby-drb TCP──▶  daemon (PicoRuby)
                                          │  ├─ BLE central  → StackChan (NUS)
                                          │  └─ picoruby-drb TCP ▶ sidecar (CRuby)
                                          │                          ├─ Apple Foundation Model (chat)
                                          │                          └─ say + afconvert → mu-law (say)
```

- **CLI / daemon**: PicoRuby (`StackChan::Controller::CLI`, `StackChan::Controller::Daemon`
  in `mrbgems/picoruby-stackchan-controller`). The daemon serves the action
  table `apps/mac/app.rb` declares; the CLI sends each verb as `act(verb, args)`
  and prints the answer. Tasks are timesliced: the drb accept loop and a
  250 ms tick (keepalive, touch delivery, `every`) are Tasks, a one-token
  `Task::Queue` serialises BLE access, and touch events wait in a list of at
  most 16 that `touch listen` polls.
- **Link** (`StackChan::Controller::Link`): a clocked state machine. See
  "Link lifecycle" below.
- **BLE**: `StackChan::Controller::Nus` (UUID→handle, frame classify),
  `StackChan::Controller::Radio` (the `BLE` subclass) and
  `StackChan::Controller::Central` (verb-facing wrapper) are host-tested in `test/pc` (`SUITE=pc bundle exec rake test` from
  the repo root) against a `BLE` stub and `FakeRadio`. They implement
  scan/connect/GATT-discover/CCCD-subscribe/write/ACK, dRuby audio, and
  reconnect. `scan` re-powers the controller and the port flushes in-flight
  packets, so it runs only from `connect` (the initial connect and a
  reconnect); everything else drains with `pop_and_dispatch`. `app/fake_ble.rb`
  (`bundle exec rake pc:up BLE_FAKE=1`) swaps in for verb-logic testing without
  hardware.
- **sidecar**: `../sidecar/sidecar.rb` (CRuby). Returns data only (reply text /
  mu-law bytes); never touches BLE.

## Run (dev / host)

Build the deployment VM once. `vendor/R2P2-darwin` is
fetched via `rake vendor:r2p2_darwin:setup` from the repo root (see the
top-level README); it vendors picoruby itself (`port-darwin` branch — BLE +
mbedtls + io-console + machine darwin ports) internally. From the repo root:

```sh
bundle exec rake pc:vm_build   # vendor/R2P2-darwin/build/host/bin/picoruby
```

The VM carries no StackChan code: the daemon loads `picoruby-stackchan-controller`
(`StackChan::Controller`, including `SendBuilder` and the `Error` hierarchy) and
`picoruby-stackchan-protocol`
(`StackchanProtocol::FrameParser`, `Stackchan::BLE::FrameCodec`, `Stackchan::AI::FrameText`)
as source from the checkout it runs from.

Then package that VM into `~/Applications/StackchanPico.app` (from the repo
root; required once, and again after every `pc:vm_build`, so real-mode BLE
can pass macOS TCC — see "macOS TCC / CoreBluetooth" below):

```sh
bundle exec rake pc:app_bundle
```

Then bring the backends up under launchd — `STUB=1` picks the stub sidecar
(no Apple Foundation Model / say / afconvert calls), omit it for the real
sidecar:

```sh
bundle exec rake pc:up STUB=1       # omit STUB=1 for the real FM + say/afconvert sidecar
```

Then drive them through the wrapper, which only attaches (connects to a
physical StackChan by default):

```sh
pc/stackchan-pico/bin/stackchan face joy
pc/stackchan-pico/bin/stackchan led left red blink
pc/stackchan-pico/bin/stackchan chat "やあ"
pc/stackchan-pico/bin/stackchan say "こんにちは" --gain 0.1
pc/stackchan-pico/bin/stackchan demo --duration 8
pc/stackchan-pico/bin/stackchan tui
pc/stackchan-pico/bin/stackchan calibrate --align-only
pc/stackchan-pico/bin/stackchan status
pc/stackchan-pico/bin/stackchan stop
```

Verbs are the actions `apps/mac/app.rb` declares (face, led, servo, torque,
selftest, say, chat, demo) plus the built-ins connect, status, stop, raw,
calibrate, remote, touch and tui. `stackchan` with no verb asks the daemon for
the list, so it needs the backends running. `tui` reads one action per line
with its arguments (`face joy`, `servo --yaw-left 50 --time 500`), `h` lists
the verbs and `q` quits.

`status` prints one line of `key=value` pairs: `link` (`released`, `held`,
`quiet` or `busy`), `connects`, `releases`, `last_connect_ms`, `hold_ms`,
`ble_connected`, `last_face`, `last_action`, `host`, `port`.

`touch listen [--count N] [--timeout SEC]` connects, prints
`touch zone=N (back|right|left)` per tap, and exits 0 after N taps, or 1 with
`[touch] timed out` or `[touch] released`.

Exit codes: 0 done, 1 error or unknown verb, 6 calibration needed, 7 verify
fail or calibration aborted, 8 busy (`busy: robot is held by another
controller or unreachable`).

**Use `bundle exec rake pc:down` to stop the backends.** It boots both jobs
out and removes their plists from `~/Library/LaunchAgents/`. The `stop` verb
is not the same thing: it asks the daemon to exit — launchd leaves it down,
since `KeepAlive` only restarts an abnormal exit — but the plist stays, so
the daemon returns at the next login. `stop` returns once the daemon has
answered and prints "daemon stopped". The darwin central cannot close a GAP
connection, so the robot releases the link itself 15 s after the last frame
it received (or the Mac's own idle drop comes first). A verb has no time
limit, so against a wedged daemon it hangs rather than failing.

`bin/stackchan` env (it only attaches):
`STACKCHAN_PICORUBY` (VM path), `STACKCHAN_ROOT`, `STACKCHAN_PORT` (8787).

`bundle exec rake pc:up` env (baked into the launchd plists it writes, not
read by the wrapper): `STUB=1` (stub sidecar), `BLE_FAKE=1` (swap in
`FakeBleClient` for testing verb logic without hardware), `ALLOW_BUSY=1`
(accept a daemon whose robot is held by another controller; without it
`pc:up` succeeds only once the daemon has connected at least once), `PREFIX=` (real mode
only, default `StackChan`), `STACKCHAN_PORT=` (daemon drb
port, default 8787), `STACKCHAN_SIDECAR_PORT=` (default 8788), `NS=` (launchd
label namespace), plus `STACKCHAN_LOGDIR` and `STACKCHAN_PICORUBY_APP`.

Use `STACKCHAN_PORT` rather than the bare `PORT` (also accepted) for the
daemon port: it is the same variable the wrapper reads, so exporting it once
keeps `pc:up` and the CLI on the same port. Set only `PORT=9999` and the
daemon listens on 9999 while every later command still asks 8787 and reports
that the backends are not running.

```sh
bundle exec rake pc:up BLE_FAKE=1   # no hardware needed
pc/stackchan-pico/bin/stackchan connect
```

## Link lifecycle

The controller holds the link only while it is in use.

- `released`: no link. The next action connects first (scan, connect,
  discover, subscribe) and the link becomes `held`.
- `held`: every 7 s without a frame the tick sends `<read:pos>` as a
  keepalive. `touch listen` polling counts as use.
- `quiet`: `c.hold` ms (`10_000` in `apps/mac/app.rb`) after the last action
  the keepalive stops. The robot releases the link 15 s after the last frame
  it received; an action before that uses the link as it is.
- The darwin central reports a disconnect as the packet `[0x3E,0x01,0x05]`,
  which the controller sees on its next drain (every tick, and before each
  action). The link then goes back to `released`, and an action that had handed the
  link back while waiting (chat on the sidecar) stops with `LinkChanged`
  rather than continuing on a new link.
- `busy`: the connect found nothing — another central (a second Mac process,
  the iOS app) holds the robot, which does not advertise meanwhile, or it is
  out of reach. The verb exits 8. Nothing retries in the background; the
  next action tries again.
- An ACK timeout on a link that is still up fails that verb and keeps the
  link. `StackChan::Controller::Central#disconnect` only clears local state:
  the darwin central port has no API to close a GAP connection (see the
  top-level README's Dependencies / picoruby fork entry).

`BLE_FAKE=1` (`rake pc:up`, host, no radio) covers every verb except
`remote`, including real FM chat and real say/afconvert, for testing verb
logic without hardware.

## macOS TCC / CoreBluetooth

macOS hard-aborts (TCC, `SIGABRT`) any CoreBluetooth call from a process not
launched through LaunchServices out of an app bundle declaring
`NSBluetoothAlwaysUsageDescription`, or as a launchd job — a direct fork/exec
from a shell, even signed and previously authorized, always crashes.
`bundle exec rake pc:up` launches the daemon as a LaunchAgent whose
`ProgramArguments` points straight at the binary inside the signed
`~/Applications/StackchanPico.app` bundle (built by `rake pc:app_bundle`,
path overridable with `STACKCHAN_PICORUBY_APP`); launchd is an acceptable
responsible process for TCC, so this needs no `open -a` step. Rebuild the bundle (`rake pc:app_bundle`) after every
`pc:vm_build` — the ad-hoc code signature, and the TCC authorization tied to
it, is bound to the binary's exact bytes.

## PicoRuby constraints worked around

No Mutex/Thread (timesliced Tasks, `Task::Queue`); drb carries no kwargs (Hash args) and
no remote block (poll, not yield-back); `system` can't background/redirect
(launchd spawns the backends, not this wrapper); regexp has no `|` alternation; `gsub`/`sub`
mishandle multibyte (each_char); `module_function` bare form is a no-op; strings
from PicoRuby arrive ASCII-8BIT in CRuby (re-tag UTF-8 at the sidecar boundary).
