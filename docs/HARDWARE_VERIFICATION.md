# Hardware verification — pending steps

This file lists every verification step from the stackchan-display bring-up plan
that requires physical M5Stack CoreS3 hardware. The ILI9342 driver and all
example scripts are host-tested (`mrbgems/picoruby-ili9342/` — 21 tests pass)
but not yet flashed.

Run these in a session with:
- ESP-IDF v5.4 sourced (`. ~/esp/v5.4/esp-idf/export.sh` or equivalent)
- M5Stack CoreS3 connected via USB-C
- `bash0C7/R2P2-ESP32` checked out at branch `feature/cores3-stackchan` (commit `38f5046` adds `picoruby-ili9342` to the build_config)

## Plan reference

Source: `docs/superpowers/plans/2026-05-10-stackchan-display-bringup.md`

The pending steps map to original plan tasks:

| Plan task | What | Why pending |
|---|---|---|
| 4 | Flash vanilla R2P2-ESP32 to CoreS3, confirm REPL boot | physical device + USB |
| 15 step 3 | `rake build` of R2P2-ESP32 with picoruby-ili9342 wired | needs ESP-IDF v5.4 (was not on PATH) |
| 16 | Flash ili9342-enabled build, smoke-test `require 'ili9342'` + `ILI9342.new` + `d.fill(0x0000)` | physical device |
| 22 | Copy `face_neutral.rb` to `/home/app.rb`, reboot, confirm autostart | physical device |
| 23 step 2 | Run `examples/benchmark_fill.rb`, capture average ms | physical device |

## Step-by-step procedure

### Phase 1 — Vanilla boot (Plan Task 4)

```bash
cd /Users/bash/dev/src/github.com/bash0C7/R2P2-ESP32
git switch master           # vanilla, before our gem
export SDKCONFIG_DEFAULTS="sdkconfigs/usb_console;sdkconfigs/spiram"
rake setup_esp32s3
rake build && rake flash && rake monitor
```

Pass criterion: R2P2 banner + `> ` prompt within 5 s of reset. In REPL:

```ruby
> 1 + 1
=> 2
> require 'gpio'
=> true
> require 'spi'
=> true
```

If `require 'spi'` fails: vanilla build is missing the spi mrbgem — check `xtensa-esp-picoruby.rb`.

### Phase 2 — Build with picoruby-ili9342 (Plan Task 15 step 3 + Task 16)

```bash
cd /Users/bash/dev/src/github.com/bash0C7/R2P2-ESP32
git switch feature/cores3-stackchan   # picoruby-ili9342 wired in
rake build
```

If build fails on `picoruby-ili9342` linkage: check the `gemdir:` path in
`components/picoruby-esp32/build_config/xtensa-esp-picoruby.rb` is reachable
from this machine.

```bash
rake flash && rake monitor
```

In REPL:

```ruby
> require 'ili9342'
=> true
> ILI9342::CMD_DISPON
=> 41
> ILI9342::Color::RED
=> 63488
```

### Phase 3 — Real display init + first pixels (Plan Task 16 step 3)

CoreS3 LCD reset and backlight are routed through the AW9523 IO Expander and
AXP2101 PMIC respectively, not direct GPIOs. The driver currently accepts
GPIO objects for `rst_pin:` / `bl_pin:` and the example scripts pass
placeholder GPIO numbers (1 and 2) — the SWRESET command (`0x01`) inside
`INIT_COMMANDS` substitutes for hardware reset, and USB power keeps the
backlight on.

```ruby
> spi = SPI.new(unit: :ESP32_SPI3_HOST, frequency: 40_000_000,
                sck_pin: 36, copi_pin: 37, cs_pin: 3, mode: 2)
> dc  = GPIO.new(35, GPIO::OUT)
> cs  = GPIO.new(3,  GPIO::OUT)
> rst = GPIO.new(1,  GPIO::OUT)   # placeholder — see _Limitations_ below
> bl  = GPIO.new(2,  GPIO::OUT)   # placeholder
> d   = ILI9342.new(spi: spi, dc_pin: dc, cs_pin: cs, rst_pin: rst, bl_pin: bl,
                    width: 320, height: 240, rotation: :landscape)
=> #<ILI9342:...>
> d.fill(0x0000)
=> nil
```

Pass criterion: screen turns solid black.

If screen stays white / shows garbage:
1. Confirm SPI host is `ESP32_SPI3_HOST` (not SPI2)
2. Confirm SPI mode is `2` (CPOL=1, CPHA=0) — see `mrbgems/picoruby-ili9342/docs/cores3-pinout-and-init.md`
3. Confirm BGR + invert ON in `INIT_COMMANDS` (entries `0x36 [0x08]` and `0x21 []`)
4. Try the alternate MADCTL value `0x00` (clear BGR bit) — some panel revisions are RGB
5. Compare actual SPI byte stream against `INIT_COMMANDS` using a logic analyzer

### Phase 4 — Example scripts (Plan Tasks 17, 18, 19, 20, 21)

All under `mrbgems/picoruby-ili9342/examples/`. Transfer to `/home/` on the
device (via picomodem or your terminal's drag-and-drop), then in REPL:

```ruby
> load '/home/black_fill.rb'   # solid black
> load '/home/color_cycle.rb'  # red → green → blue, 1 s each
> load '/home/face_neutral.rb' # face with horizontal mouth
> load '/home/face_smile.rb'   # face with mild upward mouth curve
> load '/home/face_joy.rb'     # face with large upward mouth curve
> load '/home/avatar_demo.rb'  # cycles 3 expressions every 5 s, infinite loop
```

Note: `face_*.rb` use `require_relative '_face'` which may not be supported
on PicoRuby. If `LoadError`, copy `_face.rb` to `/home/` first and edit the
require to `require '_face'`.

### Phase 5 — Autostart (Plan Task 22)

```ruby
> # in REPL, with face_neutral.rb already on /home/:
> require 'fat-fs'  # or whatever R2P2 fs API is
> # cp /home/face_neutral.rb to /home/app.rb (use whatever copy is available)
```

Then physical reset of CoreS3. Pass criterion: neutral face appears on screen
within ~5 s of reset, no REPL interaction needed.

### Phase 6 — Performance (Plan Task 23 step 2)

```ruby
> load '/home/benchmark_fill.rb'
fill() x5 avg: <X.Y> ms
```

Capture the printed average and replace the `_TBD_` placeholder in
`mrbgems/picoruby-ili9342/README.md` "Performance baseline" section.

If `Machine.uptime_us` is not available on R2P2-ESP32, swap for whatever
microsecond-precision time source is exposed (`Time.now.to_f * 1_000_000`,
`PicoTime.now`, etc).

## Limitations to fix in follow-up specs

These are known gaps that real hardware will surface; not bugs in the current
driver but missing scope:

- **AW9523 IO Expander driver** needed for proper LCD reset (currently a
  software SWRESET via init cmd `0x01` is enough for first-light, but a real
  reset requires toggling AW9523 P1.1 / reg `0x03` per upstream `stackchan.cc`
  lines 168-175).
- **AXP2101 PMIC driver** needed for backlight on/off control (currently the
  panel is on by default with USB power).
- **`picoruby-machine` `delay_ms` / `uptime_us`** — verify symbols actually
  exist on R2P2-ESP32 build; if naming differs, adjust `mrblib/ili9342.rb` and
  `examples/benchmark_fill.rb`.
- **`Float#round` and `Float#**`** in `draw_ellipse` — verify
  picoruby-float build is included; integer-only fallback exists in
  `docs/superpowers/plans/2026-05-10-stackchan-display-bringup.md` Task 13
  if needed.
- **`require_relative`** in face_*.rb examples — confirm support on PicoRuby
  or document the `/home/` copy + plain `require` workaround.

## After successful verification

1. Replace `_TBD_` in `mrbgems/picoruby-ili9342/README.md` with the measured
   `fill()` ms.
2. Update root `README.md` status table: change `LCD (ILI9342) | host-tested,
   hardware-untested` to `working on CoreS3` (and similar for face row).
3. Decide branch fate (merge `feature/stackchan-display-bringup` to `main` or
   keep as-is for follow-up specs).
