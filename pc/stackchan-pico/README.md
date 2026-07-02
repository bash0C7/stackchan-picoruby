# pc/stackchan-pico — PC side in PicoRuby

The Mac-side StackChan controller, rewritten in PicoRuby so both ends (device
firmware and PC) run the same language/runtime. Functional parity with the
CRuby `pc/stackchan` for every CLI verb; Apple Foundation Model + macOS TTS
stay in a CRuby sidecar bridged over dRuby.

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
  scan/connect/GATT-discover/CCCD-subscribe/write/ACK — logic-verified on host
  by simulating device round-trips (see the file's header comment for the
  design, and the load-bearing gotcha around calling `start`/`scan` again
  after the initial connect); live scan/connect against a **physical**
  StackChan is still pending. `app/fake_ble.rb` stands in for host runs.
- **sidecar**: `../sidecar/sidecar.rb` (CRuby). Returns data only (reply text /
  mu-law bytes); never touches BLE.

## Run (dev / host)

Build the deployment VM once (shared gem baked in):

```sh
cd ../picoruby-ble-darwin-port   # the bash0C7/picoruby darwin-ble worktree
MRUBY_BUILD_DIR="$PWD/build-stackchan-pc" \
MRUBY_CONFIG=../R2P2-macOS/build_config/r2p2-stackchan-pc.rb \
LDFLAGS="-L/opt/homebrew/opt/openssl@3/lib" CFLAGS="-I/opt/homebrew/opt/openssl@3/include" \
rake
# → build-stackchan-pc/host/bin/picoruby  (Stackchan::BLE / Stackchan::AI compiled in)
```

Then drive it through the wrapper (auto-starts the sidecar + daemon):

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
raw, touch, demo, tui, calibrate — same surface as CRuby `pc/stackchan`.

`bin/stackchan` env: `STACKCHAN_PICORUBY` (VM path), `STACKCHAN_ROOT`,
`STACKCHAN_PORT` (8787), `STACKCHAN_SIDECAR_PORT` (8788), `STACKCHAN_SIDECAR_STUB`,
`STACKCHAN_BLE_REAL=1` (drive a physical StackChan via `StackchanCentral`
instead of the default `FakeBleClient`), `STACKCHAN_BLE_NAME_PREFIX` (real mode
only, default `StackChan`).

```sh
STACKCHAN_BLE_REAL=1 pc/stackchan-pico/bin/stackchan connect   # physical device
```

## Status

- Verified on host (FakeBleClient): every verb, chat via REAL FM, say via REAL
  say/afconvert, demo/tui/calibrate flows, touch polling. Works on both a plain
  VM (mrblib `load`ed) and the deployment VM (gem baked in).
- **Live BLE (real StackChan) is sub-project #5.** `StackchanCentral`/
  `StackchanRadio` are implemented and logic-verified on host (simulated device
  round-trips: ACK, servo detail frame, device-rejected ACK, ACK timeout, touch
  notification, CCCD subscribe, and every `connect` error path). Confirmed
  against no physical device: `STACKCHAN_BLE_REAL=1 ... connect` scans for the
  full timeout and fails with a clear `ConnectionError` (not a hang or crash).
  What's still unverified: scan/connect/discovery against an **actual**
  advertising StackChan, and the CCCD-subscribe → real notification path this
  depends on.

## PicoRuby constraints worked around

No Mutex/Queue/Thread (cooperative Tasks); drb carries no kwargs (Hash args) and
no remote block (poll, not yield-back); `system` can't background/redirect
(spawning is in this shell wrapper); regexp has no `|` alternation; `gsub`/`sub`
mishandle multibyte (each_char); `module_function` bare form is a no-op; strings
from PicoRuby arrive ASCII-8BIT in CRuby (re-tag UTF-8 at the sidecar boundary).
