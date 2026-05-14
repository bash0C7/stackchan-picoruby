# Hardware verification — stackchan-protocol

Manual steps to verify `picoruby-stackchan-protocol` (StackChan side) and
`pc/stackchan-protocol` (PC side) on a real M5Stack CoreS3. All host-side
unit tests pass under `bundle exec rake test`; this doc covers what host
tests cannot — real ILI9342 panel rendering, autostart of `/home/app.rb`,
and serial round-tripping over USB-CDC.

Run these in a session with:
- ESP-IDF v5.4 sourced
- M5Stack CoreS3 connected via USB-C → `/dev/cu.usbmodem1101` enumerated
- `bash0C7/R2P2-ESP32` checked out at the branch where the
  `picoruby-stackchan-protocol` `conf.gem path:` is wired in
  (Task 27 of `docs/superpowers/plans/2026-05-14-stackchan-protocol.md`)
- This repository on branch `feature/stackchan-display-bringup` (or wherever
  Tasks 1–26 of the same plan were merged)

## Prerequisites carried over from display bring-up

The pending phases of `docs/HARDWARE_VERIFICATION.md` are not duplicated
here. **You must successfully complete Phases 1–3 of that doc first**
(vanilla R2P2 boots, `require 'ili9342'` works, `d.fill(0x0000)` blanks
the screen). The phases below assume those checkpoints are green.

## Phase 1 — Build & flash with both mrbgems wired

```bash
cd /Users/bash/dev/src/github.com/m5stack/stackchan-picoruby
rake r2p2:build_flash
```

Pass criterion: `flash complete` in `tmp/longrun/build_flash.log` and CoreS3
reboots into the R2P2 banner.

## Phase 2 — Autostart smoke test (Goal §2 item 1)

1. Open `https://picoruby.org/terminal` in Chrome/Edge, baud 115200,
   port `/dev/cu.usbmodem1101`, connect.
2. In the terminal's `path-input` field, type `/home/app.rb`.
3. `Open local file` →
   `mrbgems/picoruby-stackchan-protocol/examples/app.rb` → mode `Plain` →
   `Upload`. Wait for `done` log.
4. Physical reset of CoreS3 (RST button or `rake r2p2:reset`).

Pass criterion: within ~5 s of reset the screen shows a neutral face (two
white round eyes + a straight horizontal mouth) on a black background. No
keyboard interaction needed.

## Phase 3 — PC client install (Goal §2 item 2)

```bash
cd pc/stackchan-protocol
bundle install --path vendor/bundle
```

Pass criterion: `Bundle complete!`. `uart` and its `ruby-termios`
transitive dependency build cleanly.

## Phase 4 — Face switching (Goal §2 items 3-4)

With CoreS3 still on the neutral-face autostart screen:

```bash
cd pc/stackchan-protocol
bundle exec stackchan-control --port /dev/cu.usbmodem1101 smile
```

Pass criterion: within ~1 s the mouth changes to a mild upward V shape
(corner_y = 138, lifted 8 px from neutral). No CLI error output, exit 0.

```bash
bundle exec stackchan-control --port /dev/cu.usbmodem1101 joy
bundle exec stackchan-control --port /dev/cu.usbmodem1101 neutral
```

Pass criterion: face switches to joy (corner_y = 128, lifted 18 px) then
back to neutral. Each call returns exit 0.

## Phase 5 — Error byte round-trip (Goal §2 item 5)

```bash
bundle exec stackchan-control --port /dev/cu.usbmodem1101 raw 9
```

Pass criterion: screen unchanged. CLI prints something like:
```
device error: device reported '?' for face=... (or for raw send)
```
…and exits 1.

If exit is 0 with no stderr, the `'?'` ack path is broken — most likely
StackChan side `STDOUT.write('?')` is buffered. Confirm `$stdout.sync = true`
is in `examples/app.rb` and `examples/app.rb` was re-uploaded.

If `set_face` reports DeviceError after `neutral`/`smile`/`joy` (Phase 4)
when it should be silent, R2P2 boot ASCII is still leaking after autostart
takes STDIN. Try adding `Client#drain` before `set_face`:
```ruby
client.open do |s|
  client.drain(s, timeout: 1.0)
  client.set_face(s, :smile)
end
```
…and patch `exe/stackchan-control` if reproducible.

## Phase 6 — Stability (Goal §2 item 6)

Run 20 face switches in a row:
```bash
for f in smile joy neutral smile joy neutral smile joy neutral smile \
         joy neutral smile joy neutral smile joy neutral smile joy; do
  bundle exec stackchan-control --port /dev/cu.usbmodem1101 $f || exit 1
  sleep 0.3
done
```

Pass criterion: all 20 succeed (exit 0). Face is correct after the loop.
No `irb` / interactive shell on CoreS3 — the autostart loop is the only
consumer of STDIN.

## Open questions — resolved (2026-05-14)

All R1–R6 from spec §11 resolved during this verification session.

| # | Question | Result |
|---|---|---|
| R1 | `wait_readable` timeout on uart gem | OK — `UART.open` returns a regular `File`; `io.wait_readable(t)` works directly |
| R2 | Boot log noise mixing into protocol STDOUT | OK — `Dispatcher#run` owns STDIN after autostart; no `Client#drain` needed |
| R3 | `STDIN.read(1)` blocking on PicoRuby 4.0 | OK — blocks; `main_task` does not return after autostart |
| R4 | `$stdout.write('?')` flush | OK — `:sync=` absent on PicoRuby `$stdout` but write reaches PC instantly (probed with 1 byte raw send → 1 byte `?` ack within 2 s) |
| R5 | Autostart STDIN/STDOUT ownership | OK — shell `$>` does not appear; PC bytes route straight to `Dispatcher` |
| R6 | Phase-6 stability (20 face switches in a row) | OK — all 20 PASS |

## Build-infrastructure notes (discovered during verification)

- The `r2p2:setup` step is **mandatory** whenever a new `conf.gem` line is added to `bash0C7/R2P2-ESP32/components/picoruby-esp32/build_config/xtensa-esp-picoruby.rb`. `idf.py build` alone does not regenerate `picoruby/build/.../mrbgems/gem_init.c` / `picogem_init.c`, so the new gem will fail to load at runtime.
- When only `mrblib/*.rb` content inside an **existing** gem changes (e.g. tweaking a constant), `idf.py build` keeps the stale cached `<gem>/mrblib/<gem>.c` bytecode because CMake's `add_custom_command(OUTPUT libmruby.a COMMAND ... rake)` only depends on the output file. Use `rake r2p2:rebuild_gems` to delete `libmruby.a`; the next `rake r2p2:build_flash` then forces picoruby's `rake` to re-run mrbc on every gem and re-link. Recommended pair: `rake r2p2:rebuild_gems r2p2:build_flash`.
- `conf.gem` must use `gemdir:` (not `path:`). PicoRuby's `MRuby::LoadGems` does not accept `path:`.
- The require name is the gem name with `picoruby-` stripped — so `picoruby-stackchan-protocol` is loaded with `require 'stackchan-protocol'` (hyphen). Host tests can use the file-name form `require 'stackchan_protocol'` via `$LOAD_PATH`; only the on-device require has to match the prebuilt gem name.
- USB-CDC port enumerates as `/dev/cu.usbmodem101` on one CoreS3 unit and `/dev/cu.usbmodem1101` on others. The repo `Rakefile` auto-detects `/dev/cu.usbmodem*` for all `rake r2p2:*` tasks (override with `ESPPORT=...` only when 2+ candidates exist).

## Claude-Code-side picomodem upload

`https://picoruby.org/terminal` is the canonical Upload entry point, but it requires a human Chrome session. For autonomous flows there is `tmp/picomodem_upload.rb` (host CRuby + the `uart` gem from `pc/stackchan-protocol/vendor/bundle`) which sends `STX` + `FILE_WRITE` + chunked `CHUNK` frames matching `picoruby-picomodem`'s wire format. Useful for re-uploading `examples/app.rb` after every code change without leaving the terminal.

Note: if the device is stuck in a crash-loop or `main_task` has returned (e.g. autostart raised an uncaught exception), the shell will not service incoming `STX` frames. Recovery is `rake r2p2:flash` to re-flash `storage.bin` and reset `/home/`.

## After successful verification

1. ✅ `README.md` status table updated to `working on CoreS3 (2026-05-14)`.
2. ✅ Build-infra workarounds folded into the project CLAUDE.md / spec §11 (see "Build-infrastructure notes" above).
3. Decide branch fate (merge `feature/stackchan-display-bringup` to `main` together with stackchan-protocol, or keep separate per remaining bring-up tasks in `HARDWARE_VERIFICATION.md`).
