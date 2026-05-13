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

## Open questions to resolve during this verification (spec §11)

| # | Question | Where to check |
|---|---|---|
| R3 | Is `STDIN.read(1)` blocking on PicoRuby 4.0 / R2P2-ESP32? | Phase 2: if face appears immediately at boot before any PC byte is sent, the `Dispatcher#run` loop is spinning — that means `read(1)` returned nil quickly. Should not happen if `STDIN.read(1)` blocks. If it does, add a `Machine.delay_ms(1)` inside the loop or switch to `STDIN.getc`. |
| R4 | Does `$stdout.write('?')` flush in time for PC `IO.select` window? | Phase 5: if `raw 9` doesn't trigger DeviceError, the `'?'` is buffered. `$stdout.sync = true` in `examples/app.rb` is the first remedy. |
| R5 | Does autostart `app.rb` actually own STDIN/STDOUT? | Phase 2: if app.rb never runs (no face appears) but R2P2 banner shows up over PC serial, autostart is not handing the channels over. Re-check `/home/app.rb` was uploaded. |
| R6 | Does R2P2 boot log noise reach the PC after autostart? | Phase 5: if `neutral/smile/joy` produce spurious DeviceError, boot noise is still leaking. Mitigation: `Client#drain` before sending. |

## After successful verification

1. Update `README.md` status table: change `protocol | host-tested,
   hardware-untested` → `working on CoreS3` (or analogous).
2. If R3/R4/R5/R6 surfaced workarounds, fold them into either
   `examples/app.rb` or `Client` defaults and add a regression test on the
   host side.
3. Decide branch fate (merge `feature/stackchan-display-bringup` to `main`
   together with stackchan-protocol, or keep separate per remaining
   bring-up tasks in `HARDWARE_VERIFICATION.md`).
