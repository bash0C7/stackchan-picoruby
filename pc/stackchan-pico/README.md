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
  host-verified; `StackchanCentral` radio I/O is live-pending sub-project #5
  (needs the physical device). `app/fake_ble.rb` stands in for host runs.
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
`STACKCHAN_PORT` (8787), `STACKCHAN_SIDECAR_PORT` (8788), `STACKCHAN_SIDECAR_STUB`.

## Status

- Verified on host (FakeBleClient): every verb, chat via REAL FM, say via REAL
  say/afconvert, demo/tui/calibrate flows, touch polling. Works on both a plain
  VM (mrblib `load`ed) and the deployment VM (gem baked in).
- **Live BLE (real StackChan) is sub-project #5** — `StackchanCentral` radio I/O
  is written but unverified; needs the physical device.

## PicoRuby constraints worked around

No Mutex/Queue/Thread (cooperative Tasks); drb carries no kwargs (Hash args) and
no remote block (poll, not yield-back); `system` can't background/redirect
(spawning is in this shell wrapper); regexp has no `|` alternation; `gsub`/`sub`
mishandle multibyte (each_char); `module_function` bare form is a no-op; strings
from PicoRuby arrive ASCII-8BIT in CRuby (re-tag UTF-8 at the sidecar boundary).
