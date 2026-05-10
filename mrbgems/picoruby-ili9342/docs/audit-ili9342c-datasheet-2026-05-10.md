# picoruby-ili9342 — Datasheet audit (2026-05-10)

Cross-check of `mrblib/ili9342.rb` `INIT_COMMANDS` and primitives against
the **official Ilitek ILI9342C datasheet, Version V100**, 235 pages.

- Datasheet URL (M5Stack-hosted, vendor copy):
  <https://m5stack.oss-cn-shenzhen.aliyuncs.com/resource/docs/datasheet/core/ILI9342C-ILITEK.pdf>
- Local cache: `tmp/datasheets/ILI9342C-ILITEK.pdf` (excluded from git)
- Auditor: Claude (this session), invoked because INIT_COMMANDS was
  originally written from ESP-IDF / LovyanGFX / ILI9341 references rather
  than the ILI9342C primary source.

## TL;DR

- **Level-1 commands** (no EXTC unlock needed) — **all correct**. The
  display will boot, sleep-out, switch to BGR + 16bpp + invert + landscape
  + display-on, and accept CASET / RASET / RAMWR streams as the driver
  emits them.
- **Level-2 commands** (require `Set EXTC C8h = FF 93 42` first) — driver
  **does not send EXTC**, so the entire C0/C1/C5/C7/B1/B6/E0/E1/0xCF/
  0xED/0xE8/0xCB/0xF7/0xEA/0xF2 block is silently NOP'd by the chip.
  Several of those bytes are **not even ILI9342C commands** (they are
  ILI9341 reference-init bytes pasted in from the wrong datasheet).
- **Hardware reset timing** is conservative-correct (driver is more
  lenient than the spec requires; datasheet asks for tRW ≥ 10 µs and
  tRT ≤ 120 ms; driver does 20 ms / 120 ms).
- **MADCTL bit field** is verified: `MY MX MV ML BGR MH X X` (D7..D0),
  matching the four `MADCTL_*` constants in the driver.
- **Pin numbers / SPI freq / SPI mode / BGR / invert** were already
  verified earlier against upstream `firmware/main/hal/board/stackchan.cc`
  by a separate Explore subagent — see audit summary in the body of
  this doc, "Pin / electrical layer" section.

## Per-command verdict

| Cmd | Datasheet section | Datasheet says | Driver sends | Verdict |
|-----|-------------------|----------------|--------------|---------|
| 0x01 SWRESET   | §8.2.2  | no params | `[]` | ✅ |
| 0x11 SLPOUT    | §8.2.12 | no params | `[]` | ✅ |
| 0x21 INVON     | §8.2.16 | no params | `[]` | ✅ |
| 0x26 GAMSET    | §8.2.17 | 1 param `GC[7:0]` | `[0x01]` | ✅ |
| 0x29 DISPON    | §8.2.19 | no params | `[]` | ✅ |
| 0x2A CASET     | §8.2.20 | 4 params `SC[15:8] SC[7:0] EC[15:8] EC[7:0]` | matches | ✅ |
| 0x2B RASET     | §8.2.21 | 4 params (page) | matches | ✅ |
| 0x2C RAMWR     | §8.2.22 | 16-bit per pixel, high byte first when DBI=5 | matches | ✅ |
| 0x36 MADCTL    | §8.2.29 | 1 param `MY MX MV ML BGR MH X X` | constants set this layout | ✅ |
| 0x3A COLMOD    | §8.2.33 | 1 param `DPI[2:0] / DBI[2:0]`; 0x55 = both 5 = 16bpp | `[0x55]` | ✅ |
| **C8h SETEXTC**| §8.3.24 | **must be sent with `FF 93 42` to enable any Level-2 command** | **not sent** | 🚨 missing prerequisite |
| 0xCF | not in command list | — | `[0x00, 0xC1, 0x30]` | ❌ unknown command (treated as NOP per Note 1) |
| 0xED | not in command list (only used in a gamma timing diagram) | — | `[0x64, 0x03, 0x12, 0x81]` | ❌ unknown command |
| 0xE8 | not in command list | — | `[0x85, 0x00, 0x78]` | ❌ unknown command |
| 0xCB | not in command list | — | `[0x39, 0x2C, 0x00, 0x34, 0x02]` | ❌ unknown command |
| 0xF7 | not in command list | — | `[0x20]` | ❌ unknown command |
| 0xEA | not in command list | — | `[0x00, 0x00]` | ❌ unknown command |
| 0xC0 PWCTRL1   | §8.3.16 | **2 params** `VRH1[4:0]`, `VRH2[4:0]` | `[0x23]` (1 byte only) | ❌ wrong arity (ILI9341 has 1 param here) |
| 0xC1 PWCTRL2   | §8.3.17 | 1 param `VC[2:0] / BT[2:0]` | `[0x10]` | ⚠️ arity OK, NOP without EXTC |
| 0xC5 VMCTRL1   | §8.3.21 | **1 param** `nVM / VCM[6:0]` | `[0x3E, 0x28]` (2 bytes) | ❌ wrong arity (ILI9341 has 2 params here) |
| 0xC7           | §8.3.23 | **Set GPIO0~7 Status** — *not* VCOM Control 2 | `[0x86]` (intended as VCOMCTL2) | 🚨 wrong command identity vs ILI9341; if EXTC is ever sent, this byte writes GPO[7:0] = `1000_0110` |
| 0xB1 FRMCTR1   | §8.3.2  | 2 params `DIVA[1:0]`, `RTNA[4:0]` | `[0x00, 0x18]` | ⚠️ arity OK, NOP without EXTC |
| 0xB6 DISCTRL   | §8.3.5  | **4 params** (PTG/PT, REV/GS/SS/SM/ISC, NL, PCDIV) | `[0x08, 0x82, 0x27]` (3 bytes) | ❌ missing 4th param `PCDIV[5:0]` (ILI9341 has 3 params here) |
| 0xF2           | not in command list | — | `[0x00]` | ❌ unknown command |
| 0xE0 PGAMCTRL  | §8.3.25 | 15 params | 15 bytes | ✅ arity (NOP without EXTC) |
| 0xE1 NGAMCTRL  | §8.3.26 | 15 params | 15 bytes | ✅ arity (NOP without EXTC) |

Notes from datasheet `8.1 Command List`:
- *Note 1:* "Undefined commands are treated as NOP (00h) command."
- *Note 2:* "B0 to D9 and DE to FF are for factory use of display supplier.
  USER can decide if these commands are available or they are treated as
  NOP (00h) commands before shipping to USER. Default value is NOP (00h)."

So unknown / unenabled bytes do not crash — they are silently ignored.
This is why the driver as written might still produce visible output on
real hardware: Level-1 commands carry the visible-state setup, and the
chip's hardware-reset defaults cover the power / frame / gamma config
that Level-2 was supposed to override.

## Hardware reset timing (§A.3.5)

| Symbol | Spec | Driver | Verdict |
|--------|------|--------|---------|
| tRW (RESX low pulse) | min 10 µs | 20 ms (`Machine.delay_ms(20)`) | ✅ over-spec, harmless |
| tRT (post-reset, NV-load) | up to 120 ms (Note 1) | 120 ms (`Machine.delay_ms(120)`) | ✅ |
| (initial RESX-high settle) | not formally specified | 5 ms | ✅ conservative |

## MADCTL bit field (§8.2.29)

Datasheet table at line 3946 of the extracted text confirms bit layout:

```
36h param: D7=MY  D6=MX  D5=MV  D4=ML  D3=BGR  D2=MH  D1=X  D0=X
```

Driver constants (BGR=1 throughout, since CoreS3 panel is BGR):

| Constant               | Hex   | Bits set         | Logical orientation |
|------------------------|-------|------------------|---------------------|
| `MADCTL_LANDSCAPE`     | 0x08  | BGR              | swap_xy=false, mirror=false (CoreS3 native) |
| `MADCTL_PORTRAIT`      | 0x68  | MV+MX+BGR        | rotate 90° CW |
| `MADCTL_LANDSCAPE_FLIP`| 0xC8  | MY+MX+BGR        | rotate 180° |
| `MADCTL_PORTRAIT_FLIP` | 0xA8  | MV+MY+BGR        | rotate 90° CCW |

All four constants are bit-field-correct against the datasheet.

> Caveat carried over from the earlier audit: upstream
> `firmware/main/hal/board/stackchan.cc` does **not** write MADCTL
> directly — it uses ESP-IDF's `esp_lcd_panel_swap_xy() /
> esp_lcd_panel_mirror()` helpers, which compute MADCTL internally.
> The constants above are the natural derivation of "swap_xy=false,
> mirror_x=false, mirror_y=false, BGR" → 0x08; this matches the
> datasheet definition but is not a literal byte citation from
> upstream.

## Pin / electrical layer (re-citation)

These were verified by an Explore subagent reading
`../StackChan/firmware/main/hal/board/stackchan.cc` directly:

| Setting | Upstream citation | Value |
|---------|-------------------|-------|
| SPI host | `stackchan.cc:406` | `SPI3_HOST` |
| SCK | `stackchan.cc:402` | `GPIO_NUM_36` |
| MOSI | `stackchan.cc:400` | `GPIO_NUM_37` |
| CS | `stackchan.cc:418` | `GPIO_NUM_3` |
| DC | `stackchan.cc:419` | `GPIO_NUM_35` |
| pclk_hz | `stackchan.cc:421` | `40 * 1000 * 1000` |
| spi_mode | `stackchan.cc:420` | `2` (CPOL=1, CPHA=0) |
| pixel order | `stackchan.cc:430` | `LCD_RGB_ELEMENT_ORDER_BGR` |
| invert | `stackchan.cc:438` | `esp_lcd_panel_invert_color(panel, true)` |
| RST routing | `stackchan.cc:171-173` (`Aw9523::ResetIli9342`) | AW9523 reg 0x03 bit 1 (P1.1) |
| BL routing | `stackchan.cc:551-552, :137` | AXP2101 PMIC `SetBrightness` |
| `panel_config.reset_gpio_num` | `stackchan.cc:429` | `GPIO_NUM_NC` (reset is NOT via the LCD panel reset GPIO) |

This confirms the pin map in `cores3-pinout-and-init.md` is faithful to
upstream. The IO Expander / PMIC dependency was already documented as
out-of-scope for first-light bring-up (caller passes a placeholder GPIO
for `rst_pin:` / `bl_pin:`, and the driver substitutes `0x01 SWRESET`
for hardware reset).

## What this audit does NOT change

- No code was modified by this audit. Driver behavior is unchanged.
- All 21 host tests still pass — they assert the byte stream the driver
  emits, not whether that byte stream is the right thing to emit on
  ILI9342C silicon.

## Recommended follow-ups (defer to next session — needs hardware)

The fix shape depends on what real ILI9342C silicon does on first-light.
Three options, in order of risk:

1. **Ship as-is, see what happens.** Level-1 commands alone may produce
   acceptable output (the chip's hardware-reset defaults for power /
   frame / gamma are sane). Take photos, measure with logic analyzer,
   then decide. Lowest engineering effort — but if colors / brightness
   / refresh rate are wrong on real hardware, the visible output is
   driven by silicon defaults, not by anything the driver chose.
2. **Strip dead Level-2 bytes.** Remove 0xCF / 0xED / 0xE8 / 0xCB /
   0xF7 / 0xEA / 0xF2 / 0xC7 from `INIT_COMMANDS` since they don't
   exist on ILI9342C. Keep C0/C1/C5/B1/B6/E0/E1 around but recognize
   they're NOP'd. Honest but no behavioral change.
3. **Send EXTC unlock + correct ILI9342C parameters.** Prepend `[0xC8,
   [0xFF, 0x93, 0x42], 0]` to `INIT_COMMANDS`. Then fix the broken
   arities: 0xC0 needs 2 bytes; 0xC5 needs 1 byte; 0xB6 needs 4 bytes.
   Drop 0xC7 with `[0x86]` entirely — on ILI9342C that would write
   GPO[7:0] = `1000_0110`, which is GPIO control on a chip whose GPIOs
   may or may not be wired to anything sensitive on the CoreS3 module.
   Highest engineering effort, fully spec-compliant.

The choice should be made **with hardware in hand** — first-light
photos under option 1 will tell us which Level-2 setup actually matters
for this panel revision.

## Sub-library audit (separate concern)

A parallel review confirmed the driver's use of `picoruby-spi`,
`picoruby-gpio`, and `picoruby-machine` matches their actual ports/esp32
implementations:

- `SPI.new(unit:, frequency:, sck_pin:, copi_pin:, cs_pin:, mode:)` —
  signature confirmed at `picoruby/mrbgems/picoruby-spi/mrblib/spi.rb:11`;
  `:ESP32_SPI3_HOST` accepted at `ports/esp32/spi.c:53-68`; `spi.write`
  varargs accepts Integer / Array / String per
  `src/mruby/spi.c:114-130`.
- `GPIO.new(pin, GPIO::OUT)` — `gpio.rb:35`; `GPIO::OUT = 2` at
  `gpio.h:11` exposed at `src/mruby/gpio.c:218`; `gpio.write(0|1)` at
  `src/mruby/gpio.c:199-209`.
- `Machine.delay_ms` — module method at `picoruby-machine/src/mruby/machine.c:442`,
  ports/esp32 maps to `vTaskDelay`.
- `Machine.uptime_us` — module method at same file line 452, returns
  `esp_timer_get_time()`.

No discrepancies found in the sub-library layer.
