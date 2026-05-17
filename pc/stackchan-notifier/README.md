# stackchan-notifier

Mac-side daemon that turns Claude Code hook events into StackChan face + LED
animations over BLE NUS. A practical showcase of this repo's BLE control stack
([`pc/stackchan-ble-client`](../stackchan-ble-client) + the
`picoruby-stackchan-protocol` firmware-side gem) — not a new device subsystem.

> **Status: WIP — host implementation + tests are complete, but end-to-end
> verification against a real CoreS3 is deferred to a follow-up session.**

## Why a daemon (and not just `stackchan-ble-control` per hook)

A BLE scan + connect cycle takes ~3–5 seconds on macOS. Doing that on every
hook invocation would make `Stop` and `PreToolUse` painful. Instead:

- A long-running daemon holds **one** BLE connection.
- Hook scripts are thin DRb clients that write a 7-element tuple to the
  daemon's TupleSpace over a Unix socket — typically <100 ms wall time.
- The BLE worker thread drains additional pending tuples non-blockingly and
  sends only the **latest** one as a combo frame, so bursts of hook events
  (e.g. multiple `PreToolUse` in a row) collapse into a single BLE write.

The coordination layer is a Ractor-owned `Rinda::TupleSpace`
(`TupleSpace4Ractor`) by [関 将俊 (m_seki) / seki/ts4r](https://github.com/seki/ts4r),
exposed over DRb. The "latest-wins drain" strategy follows the same author's
[Programming with a DJ controller, not vibe coding](https://speakerdeck.com/m_seki/programming-with-a-dj-controller-not-vibe-coding) talk.

## Architecture

```
┌─────────────────────────────────────┐
│ Claude Code (per-session, short)    │
│   hook fires                        │
└──────────────┬──────────────────────┘
               │ exec
               ▼
┌─────────────────────────────────────┐
│ stackchan-notify CLI (~50 ms)       │
│   parses --face/--left_led/         │
│   --right_led/--duration flags      │
│   writes one tuple via DRb, exits   │
└──────────────┬──────────────────────┘
               │ DRb over Unix socket
               │ (drbunix:/tmp/stackchan-notifier-<uid>.sock)
               ▼
┌─────────────────────────────────────────────────────────┐
│ stackchan-notifier-daemon (long-running)                │
│  ┌─────────────────────┐    ┌──────────────────────┐   │
│  │ TupleSpace4Ractor   │◄──►│ BLE Worker Thread    │   │
│  │ (Ractor + Rinda)    │    │ - latest-wins drain  │   │
│  └─────────────────────┘    │ - auto-reconnect     │   │
│                              └──────────┬───────────┘   │
└─────────────────────────────────────────┼───────────────┘
                                          │ NUS combo frame
                                          ▼
                              ┌───────────────────────┐
                              │ StackChan (CoreS3)    │
                              └───────────────────────┘
```

## Requirements

- macOS (uses Unix sockets + `rb-corebluetooth-mac` for the underlying BLE
  client). Linux/Windows would need a different BLE transport.
- Ruby ≥ 3.3 (Ractor + `Ractor::Port`).
- Sibling clones, per the [top-level README](../../README.md):
  `stackchan-picoruby/`, `R2P2-ESP32/`, `rb-corebluetooth-mac/`, `swift_gem/`.
- A flashed CoreS3 advertising `StackChan-PicoRuby` (or any name you'll match
  with `--name-prefix`).

## Install

```bash
cd pc/stackchan-notifier
bundle install
```

## Run the daemon

```bash
bundle exec exe/stackchan-notifier-daemon
# → [...] INFO stackchan-notifier-daemon: listening on drbunix:/tmp/stackchan-notifier-<uid>.sock
```

Useful flags:

| Flag | Default | Purpose |
|---|---|---|
| `--device-name NAME` | `StackChan-PicoRuby` (or `BLE_DEVICE_NAME` env) | exact match on advertised name |
| `--name-prefix PREFIX` | none | prefix match; cooperates with macOS scan caching |
| `--socket PATH` | `/tmp/stackchan-notifier-<uid>.sock` (or `STACKCHAN_NOTIFIER_SOCKET` env) | DRb Unix socket path |
| `--log-level LEVEL` | `info` | `debug` / `info` / `warn` / `error` |

The daemon binds the socket with mode `0600` so other users on the same Mac
cannot push notifications to your StackChan.

### Signals

| Signal | Effect |
|---|---|
| `INT`, `TERM` | graceful shutdown — worker stops, DRb stops, socket unlinks |
| `HUP` | force-reconnect — worker tears down the current BLE connection and re-scans on the next loop iteration; useful when the device just came back from a silent disconnect |

### Optional: launchd plist (not provided)

A launchd plist would let the daemon survive logout / autostart at login.
This gem deliberately doesn't ship one — you'll likely want to tune the
device name, log path, and restart policy. A starting point:

```xml
<!-- ~/Library/LaunchAgents/com.bash0c7.stackchan-notifier.plist -->
<plist version="1.0"><dict>
  <key>Label</key><string>com.bash0c7.stackchan-notifier</string>
  <key>ProgramArguments</key>
  <array>
    <string>/Users/you/.rbenv/shims/bundle</string>
    <string>exec</string>
    <string>exe/stackchan-notifier-daemon</string>
  </array>
  <key>WorkingDirectory</key>
  <string>/Users/you/dev/src/github.com/bash0C7/stackchan-picoruby/pc/stackchan-notifier</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/tmp/stackchan-notifier.out.log</string>
  <key>StandardErrorPath</key><string>/tmp/stackchan-notifier.err.log</string>
</dict></plist>
```

Then `launchctl load ~/Library/LaunchAgents/com.bash0c7.stackchan-notifier.plist`.

## Configure Claude Code hooks

Add to `~/.claude/settings.json` (or a project-local equivalent):

```jsonc
{
  "hooks": {
    "Notification": [{
      "matcher": "",
      "hooks": [{
        "type": "command",
        "command": "stackchan-notify --face surprised --left_led red,blink --right_led red,blink --duration 10 --quiet"
      }]
    }],
    "Stop": [{
      "matcher": "",
      "hooks": [{
        "type": "command",
        "command": "stackchan-notify --face smile --left_led green,solid --right_led green,solid --quiet"
      }]
    }],
    "SubagentStop": [{
      "matcher": "",
      "hooks": [{
        "type": "command",
        "command": "stackchan-notify --face joy --left_led yellow,breathing --right_led yellow,breathing --quiet"
      }]
    }],
    "PreToolUse": [{
      "matcher": "Bash",
      "hooks": [{
        "type": "command",
        "command": "stackchan-notify --face neutral --left_led blue,blink --right_led blue,blink --duration 3 --quiet"
      }]
    }]
  }
}
```

The mapping of *event → (face, left LED, right LED, duration)* lives entirely in
this file. The daemon does no event-name interpretation — it just forwards the
tuple. To rebind, edit the hook command.

`--quiet` is recommended on the hook so a missing/stopped daemon never
shows noise in Claude Code's UI. The CLI still exits 0 in either case so
Claude Code is never blocked.

### `stackchan-notify` reference

| Flag | Required | Domain |
|---|---|---|
| `--face NAME` | yes | `neutral` / `smile` / `joy` / `surprised` |
| `--left_led COLOR,MODE` | no, default `0x000000,solid` (off) | COLOR = preset name or hex; MODE = `solid` / `blink` / `breathing` / `off` |
| `--right_led COLOR,MODE` | no, default `0x000000,solid` (off) | same format as `--left_led` |
| `--duration N` | no, default no auto-restore | positive integer seconds; on expiry the worker writes a neutral + both-LEDs-off tuple |
| `--socket PATH` | no | overrides default and `STACKCHAN_NOTIFIER_SOCKET` env |
| `--quiet` | no | suppresses "daemon unavailable" stderr |

**Color presets** (resolved case-sensitively against the bare name):

| Name | Hex |
|---|---|
| `red` | `0xFF0000` |
| `green` | `0x00FF00` |
| `blue` | `0x0000FF` |
| `yellow` | `0xFFFF00` |
| `white` | `0xFFFFFF` |
| `gray` | `0x808080` |
| `black` | `0x000000` |

Any 24-bit hex `0x000000..0xFFFFFF` is also accepted directly.

Exit codes:

| Code | Meaning |
|---|---|
| `0` | success, **or** daemon unavailable (intentional — never block Claude Code on missing infra) |
| `2` | invalid arguments (visible misconfiguration) |

## Testing

```bash
bundle exec rake test
```

Tests: 40 tests, 82 assertions.

Covers (no real BLE required):

- `TupleSpace4RactorTest` — write / take / read, type pattern, non-blocking drain
- `WorkerTest` — single send, drain-collapse, reconnect after send failure, backoff on connect failure, shutdown unblocks take
- `CLITest` — flag parsing, env / socket override, error exit codes, daemon-unavailable behaviour
- `DaemonTest` — Unix-socket creation w/ 0600 permission, in-process DRb round-trip through the worker to the fake BLE client, stop / shutdown lifecycle, stale-socket cleanup

**Not covered (requires a real CoreS3):**

- Actual NUS combo frame on the wire
- macOS Bluetooth scan / connect / disconnect timing
- Sleep / wake reconnect behavior
- launchd respawn

These are the next-session items.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `stackchan-notify: daemon unavailable (DRb::DRbConnError)` (no `--quiet`) | daemon not running, or socket path mismatch | start the daemon, or align `--socket` / `STACKCHAN_NOTIFIER_SOCKET` |
| Daemon log: `connect failed (attempt=…): no device named "StackChan-PicoRuby"` | CoreS3 not advertising under that name, or macOS scan cache stale | check device name, try `--name-prefix StackChan`, toggle Mac Bluetooth |
| Daemon log: `refusing to remove non-socket file at …` | something non-socket exists at the socket path | rm the file manually after verifying it's safe |
| Tests pass but live device doesn't react | wrong face/mode symbol; firmware NUS not subscribed | confirm with `bundle exec rake r2p2:ble_control_smoke …` from the repo root first |

## See also

- [seki/ts4r](https://github.com/seki/ts4r) — `TupleSpace4Ractor` originals
- [Programming with a DJ controller, not vibe coding](https://speakerdeck.com/m_seki/programming-with-a-dj-controller-not-vibe-coding) — design philosophy reference
- [`docs/superpowers/specs/2026-05-17-claude-code-notification-bridge-design.md`](../../docs/superpowers/specs/2026-05-17-claude-code-notification-bridge-design.md) — full design spec
- [`pc/stackchan-ble-client`](../stackchan-ble-client) — BLE transport this daemon delegates to
- [Stack-chan official repo](https://github.com/stack-chan/stack-chan) — the original Stack-chan project

## License

MIT — see top-level [LICENSE](../../LICENSE).
