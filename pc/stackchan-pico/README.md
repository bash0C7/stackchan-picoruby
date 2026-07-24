# pc/stackchan-pico — PC side in PicoRuby

The Mac-side StackChan controller, in PicoRuby so both ends (device firmware
and PC) run the same language/runtime — this is the operational CLI (the
earlier CRuby `pc/stackchan` CLI it replaced has been removed; `pc/stackchan`
now holds only the AI/voice sidecar support code). Apple Foundation Model and
macOS TTS stay in a CRuby sidecar bridged over dRuby.

## Architecture

```
stackchan <verb>           ← bin/stackchan (shell wrapper: process lifecycle)
   │ spawns / attaches
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
  host-verified. `StackchanCentral` (verb-facing wrapper) + `StackchanRadio`
  (the actual `BLE` subclass) implement the real picoruby-ble central —
  scan/connect/GATT-discover/CCCD-subscribe/write/ACK, half-duplex audio, and
  disconnect/reconnect self-heal — verified against a physical StackChan (see
  the file's header comment for the design, and the load-bearing gotcha
  around calling `start`/`scan` again after the initial connect).
  `app/fake_ble.rb` (`STACKCHAN_BLE_FAKE=1`) swaps in for verb-logic testing
  without hardware in the loop.
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

Then drive it through the wrapper (auto-starts the sidecar + daemon, connects
to a physical StackChan by default):

```sh
export STACKCHAN_SIDECAR_STUB=1     # omit for the real FM + say/afconvert sidecar
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

`bin/stackchan` env: `STACKCHAN_PICORUBY` (VM path), `STACKCHAN_ROOT`,
`STACKCHAN_PORT` (8787), `STACKCHAN_SIDECAR_PORT` (8788), `STACKCHAN_SIDECAR_STUB`,
`STACKCHAN_BLE_FAKE=1` (swap in `FakeBleClient` for testing verb logic without
hardware in the loop), `STACKCHAN_BLE_NAME_PREFIX` (real mode only, default
`StackChan`).

```sh
STACKCHAN_BLE_FAKE=1 pc/stackchan-pico/bin/stackchan connect   # no hardware needed
```

## Status

- **Live BLE against a physical StackChan is the default and is verified**:
  scan/connect/GATT-discover/CCCD-subscribe/write/ACK, half-duplex audio
  (say/chat), touch notifications, and disconnect/reconnect self-heal
  (`with_ble`'s reconnect on a real device reset) all confirmed on real
  hardware. `STACKCHAN_BLE_FAKE=1` (host, no radio) remains verified for
  every verb, chat via REAL FM, say via REAL say/afconvert, demo/tui/calibrate
  flows, touch polling — used for testing verb logic without hardware.

## macOS TCC / CoreBluetooth

macOS hard-aborts (TCC, `SIGABRT`) any CoreBluetooth call from a process not
launched through LaunchServices out of an app bundle declaring
`NSBluetoothAlwaysUsageDescription` — a direct fork/exec of
`build/host/bin/picoruby`, even signed and previously authorized, always
crashes. `bin/stackchan`'s real-mode daemon spawn therefore runs the VM via
`open -a` against `~/Applications/StackchanPico.app` (built by `rake
pc:app_bundle`, path overridable with `STACKCHAN_PICORUBY_APP`), never a
direct exec. Rebuild the bundle (`rake pc:app_bundle`) after every
`macos:build` — the ad-hoc code signature, and the TCC authorization tied to
it, is bound to the binary's exact bytes.

## PicoRuby constraints worked around

No Mutex/Queue/Thread (cooperative Tasks); drb carries no kwargs (Hash args) and
no remote block (poll, not yield-back); `system` can't background/redirect
(spawning is in this shell wrapper); regexp has no `|` alternation; `gsub`/`sub`
mishandle multibyte (each_char); `module_function` bare form is a no-op; strings
from PicoRuby arrive ASCII-8BIT in CRuby (re-tag UTF-8 at the sidecar boundary).
