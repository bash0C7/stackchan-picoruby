# pc/stackchan-pico — PC side in PicoRuby

The Mac-side StackChan controller, in PicoRuby so both ends (device firmware
and PC) run the same language/runtime — this is the operational CLI (the
earlier CRuby `pc/stackchan` CLI it replaced has been removed; `pc/stackchan`
now holds only the AI/voice sidecar support code). Apple Foundation Model and
macOS TTS stay in a CRuby sidecar bridged over dRuby.

## Architecture

```
stackchan <verb>           ← bin/stackchan (shell wrapper: exec only)
   │ attaches
   ▼
CLI (PicoRuby)  ──picoruby-drb TCP──▶  daemon (PicoRuby)
                                          │  ├─ BLE central  → StackChan (NUS)   [live = #5, real device]
                                          │  └─ picoruby-drb TCP ▶ sidecar (CRuby)
                                          │                          ├─ Apple Foundation Model (chat)
                                          │                          └─ say + afconvert → mu-law (say)
```

- **CLI / daemon**: PicoRuby (`app/cli_app.rb`, `app/daemon_app.rb`). Concurrency
  is cooperative Tasks (no Mutex/Queue/Thread): drb accept loop + keepalive Task,
  a `Task.pass` spinlock for BLE exclusion, an Array touch queue drained by polling.
- **BLE**: `app/ble_client.rb`. `NusResolver` (UUID→handle, frame classify) is
  host-verified. `StackchanRadio` / `StackchanCentral` are host-tested too, in
  `test/pc` (`SUITE=pc bundle exec rake test` from the repo root) against a
  `BLE` stub and `FakeRadio`. `StackchanCentral` (verb-facing wrapper) +
  `StackchanRadio` (the actual `BLE` subclass) implement the real
  picoruby-ble central —
  scan/connect/GATT-discover/CCCD-subscribe/write/ACK, half-duplex audio, and
  disconnect/reconnect self-heal — verified against a physical StackChan (see
  the file's header comment for the design, and the load-bearing gotcha
  around calling `start`/`scan` again after the initial connect).
  `app/fake_ble.rb` (`bundle exec rake pc:up BLE_FAKE=1`, was
  `STACKCHAN_BLE_FAKE=1`) swaps in for verb-logic testing without hardware
  in the loop.
- **sidecar**: `../sidecar/sidecar.rb` (CRuby). Returns data only (reply text /
  mu-law bytes); never touches BLE.

## Run (dev / host)

Build the deployment VM once (shared gem baked in). `vendor/R2P2-darwin` is
fetched via `rake vendor:r2p2_darwin:setup` from the repo root (see the
top-level README); it vendors picoruby itself (`port-darwin` branch — BLE +
mbedtls + io-console + machine darwin ports) internally:

```sh
cd ../../vendor/R2P2-darwin   # from pc/stackchan-pico/, or use the repo-root-relative path
bundle exec rake setup          # fetches R2P2-darwin's own vendor/picoruby (port-darwin branch)
MRUBY_CONFIG=build_config/r2p2-stackchan-pc.rb bundle exec rake macos:build
# → build/host/bin/picoruby  (Stackchan::BLE / Stackchan::AI compiled in)
```

Then package that VM into `~/Applications/StackchanPico.app` (from the repo
root; required once, and again after every `macos:build`, so real-mode BLE
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

Verbs: connect, status, stop, say, chat, face, led, servo, torque, selftest,
raw, touch, demo, tui, calibrate.

`stop` asks the daemon to exit; launchd leaves it down (`KeepAlive` only
restarts an abnormal exit) but its plist stays in `~/Library/LaunchAgents/`,
so it returns at the next login. `bundle exec rake pc:down` is what removes
the plists from `~/Library/LaunchAgents/` and keeps both jobs down. A verb
also has no time limit any more — against a wedged daemon it hangs rather
than failing.

`bin/stackchan` env — this is all it reads now, since it only attaches:
`STACKCHAN_PICORUBY` (VM path), `STACKCHAN_ROOT`, `STACKCHAN_PORT` (8787).

`bundle exec rake pc:up` env (baked into the launchd plists it writes, not
read by the wrapper): `STUB=1` (stub sidecar, was `STACKCHAN_SIDECAR_STUB`),
`BLE_FAKE=1` (swap in `FakeBleClient` for testing verb logic without hardware
in the loop, was `STACKCHAN_BLE_FAKE=1`), `PREFIX=` (real mode only, default
`StackChan`, was `STACKCHAN_BLE_NAME_PREFIX`), `PORT=` (daemon drb port,
default 8787), `SIDECAR_PORT=` (default 8788, was `STACKCHAN_SIDECAR_PORT`),
`NS=` (launchd label namespace), plus `STACKCHAN_LOGDIR` and
`STACKCHAN_PICORUBY_APP` (unchanged names, read the same way).

```sh
bundle exec rake pc:up BLE_FAKE=1   # no hardware needed
pc/stackchan-pico/bin/stackchan connect
```

## Status

- **Live BLE against a physical StackChan is the default and is verified**:
  scan/connect/GATT-discover/CCCD-subscribe/write/ACK, half-duplex audio
  (say/chat), and touch notifications all confirmed on real hardware.
  Reconnect after a **peripheral-side reset** (ESP32 reboots, resumes
  advertising) works via `with_ble`'s reconnect. Reconnect after an
  **ACK-timeout with the peripheral still connected is NOT reliable**:
  `StackchanCentral#disconnect` (`app/ble_client.rb`) only clears local
  state — the darwin central port has no API to actively close a GAP
  connection (see the top-level README's Dependencies / picoruby fork
  entry) — so the ESP32 peripheral never re-advertises and the following
  rescan finds nothing. `BLE_FAKE=1` (`rake pc:up`, host, no radio) remains
  verified for every verb, chat via REAL FM, say via REAL say/afconvert,
  demo/tui/calibrate flows, touch polling — used for testing verb logic
  without hardware.

## macOS TCC / CoreBluetooth

macOS hard-aborts (TCC, `SIGABRT`) any CoreBluetooth call from a process not
launched through LaunchServices out of an app bundle declaring
`NSBluetoothAlwaysUsageDescription`, or as a launchd job — a direct fork/exec
from a shell, even signed and previously authorized, always crashes.
`bundle exec rake pc:up` launches the daemon as a LaunchAgent whose
`ProgramArguments` points straight at the binary inside the signed
`~/Applications/StackchanPico.app` bundle (built by `rake pc:app_bundle`,
path overridable with `STACKCHAN_PICORUBY_APP`); launchd is an acceptable
responsible process for TCC (confirmed by a 2026-08-31 spike), so this needs
no `open -a` step. Rebuild the bundle (`rake pc:app_bundle`) after every
`macos:build` — the ad-hoc code signature, and the TCC authorization tied to
it, is bound to the binary's exact bytes.

## PicoRuby constraints worked around

No Mutex/Queue/Thread (cooperative Tasks); drb carries no kwargs (Hash args) and
no remote block (poll, not yield-back); `system` can't background/redirect
(spawning belongs to launchd now, not this wrapper); regexp has no `|` alternation; `gsub`/`sub`
mishandle multibyte (each_char); `module_function` bare form is a no-op; strings
from PicoRuby arrive ASCII-8BIT in CRuby (re-tag UTF-8 at the sidecar boundary).
