# CoreS3 ILI9342 — Pinout and Init Sequence

Extracted from M5Stack StackChan upstream firmware for use by the
`picoruby-ili9342` mrbgem (Task 7+ of the stackchan-display bring-up).

Target board: **M5Stack CoreS3 (StackChan AI desktop robot, SwSci 11129)**
LCD: **2.0" IPS 320×240, ILI9342 controller**, SPI mode 2, BGR pixel order.

> [!IMPORTANT]
> The upstream firmware does **not** ship raw init command bytes — it calls
> ESP-IDF's `esp_lcd_new_panel_ili9341()` (the IDF built-in driver supports
> the ILI9342 family) which carries the init sequence inside the IDF
> `esp_lcd` component. The Ruby `INIT_COMMANDS` array below is the
> well-known ILI9341/ILI9342 reference init from the controller datasheet,
> used as a documented fallback. Bytes can be tuned later when we flash
> hardware (Task 16).

## Pin numbers (CoreS3)

Source: `firmware/main/hal/board/stackchan.cc` `InitializeSpi()` and
`InitializeIli9342Display()` (lines 397–446).

| Role                | GPIO          | picoruby `unit:` name (planned) |
|---------------------|---------------|---------------------------------|
| `LCD_SPI_HOST`      | `SPI3_HOST`   | `:RP2040_SPI1` equivalent → ESP32-S3 SPI3 (a.k.a. HSPI). For R2P2-ESP32: `unit: :ESP32_SPI3` (see picoruby-spi enum) |
| `LCD_SCK_PIN`       | GPIO 36       | direct GPIO                     |
| `LCD_MOSI_PIN`      | GPIO 37       | direct GPIO                     |
| `LCD_MISO_PIN`      | NC (write-only) | —                              |
| `LCD_CS_PIN`        | GPIO 3        | direct GPIO                     |
| `LCD_DC_PIN`        | GPIO 35       | direct GPIO                     |
| `LCD_RST_PIN`       | **via AW9523 IO Expander, P1.1 (bit 1 of reg 0x03)** | **NOT a direct GPIO** — see notes |
| `LCD_BL_PIN`        | **via AXP2101 PMIC** (DLDO/BLDO output) | **NOT a direct GPIO** — see notes |
| `LCD_SPI_FREQ`      | 40 000 000 Hz (40 MHz) | —                          |
| Panel width         | 320           | landscape native                |
| Panel height        | 240           | landscape native                |
| SPI mode            | 2 (CPOL=1, CPHA=0) | `spi_mode: 2`              |
| Pixel order         | BGR (`LCD_RGB_ELEMENT_ORDER_BGR`) | set in MADCTL bit BGR=1 |
| Color invert        | true (`esp_lcd_panel_invert_color(panel, true)`) | issue `0x21` INVON during init |
| Default rotation    | `swap_xy=false, mirror_x=false, mirror_y=false` → **landscape, 320×240, MADCTL = 0x08** | — |

### IO Expander / PMIC pins (out-of-scope for direct SPI bring-up)

The CoreS3 wires the LCD **reset** through the **AW9523 IO Expander** (I2C
addr `0x58`, port P1, bit 1 — i.e. P1.1, the bit that toggles low→high in
upstream `Aw9523::ResetIli9342()` writes `0b1000_0001` → `0b1000_0011` to
register `0x03`) and the **backlight** through the **AXP2101 PMIC**.
These are not direct ESP32 GPIOs.

For Task 7 (init sequence) on R2P2-ESP32 we have two options:

1. **Manual reset workaround**: power-cycle the board between flashes; do
   not toggle reset from PicoRuby. Software init via `0x01` SWRESET is
   sufficient in most cases.
2. **Add AW9523 driver** (a separate mrbgem) and call
   `aw9523.write_reg(0x03, 0b1000_0001) ; sleep_ms 20 ; aw9523.write_reg(0x03, 0b1000_0011)`
   before SPI init — mirror of upstream `Aw9523::ResetIli9342()` at
   `stackchan.cc:168`.

Backlight similarly requires an AXP2101 driver; for first-light testing
the backlight is normally already on after USB power-up.

> [!WARNING]
> Per the bring-up spec, IO-expander-mediated pins are **out of scope** for
> the direct SPI driver. Task 5+ should treat reset as "external" (caller's
> responsibility) and document the AW9523 dependency in the mrbgem README.

## Init command sequence

ILI9342 / ILI9341 standard datasheet sequence (used by ESP-IDF
`esp_lcd_new_panel_ili9341`). Each entry is `[cmd_byte, [payload...], delay_ms]`.

```ruby
# Each entry: [cmd_byte, [payload_bytes...], delay_ms]
INIT_COMMANDS = [
  [0x01, [],                                                         120],  # SWRESET (software reset)
  [0x11, [],                                                         120],  # SLPOUT  (sleep out)

  # Power Control B
  [0xCF, [0x00, 0xC1, 0x30],                                           0],
  # Power on sequence control
  [0xED, [0x64, 0x03, 0x12, 0x81],                                     0],
  # Driver timing control A
  [0xE8, [0x85, 0x00, 0x78],                                           0],
  # Power Control A
  [0xCB, [0x39, 0x2C, 0x00, 0x34, 0x02],                               0],
  # Pump ratio control
  [0xF7, [0x20],                                                       0],
  # Driver timing control B
  [0xEA, [0x00, 0x00],                                                 0],

  # Power Control 1
  [0xC0, [0x23],                                                       0],  # VRH = 4.60V
  # Power Control 2
  [0xC1, [0x10],                                                       0],
  # VCOM Control 1
  [0xC5, [0x3E, 0x28],                                                 0],
  # VCOM Control 2
  [0xC7, [0x86],                                                       0],

  # Memory Access Control (MADCTL) — landscape default, BGR
  # 0x08 = MX=0 MY=0 MV=0 ML=0 BGR=1 MH=0
  # CoreS3 native is landscape 320x240 with swap_xy=false, so MADCTL=0x08
  [0x36, [0x08],                                                       0],

  # Pixel Format Set: 16-bit RGB565 (DPI/DBI = 0x55)
  [0x3A, [0x55],                                                       0],

  # Frame Rate Control: 70 Hz default
  [0xB1, [0x00, 0x18],                                                 0],
  # Display Function Control
  [0xB6, [0x08, 0x82, 0x27],                                           0],

  # Enable 3G (gamma correction disabled)
  [0xF2, [0x00],                                                       0],
  # Gamma curve selected (Gamma 2.2)
  [0x26, [0x01],                                                       0],

  # Positive Gamma Correction
  [0xE0, [0x0F, 0x31, 0x2B, 0x0C, 0x0E, 0x08, 0x4E,
          0xF1, 0x37, 0x07, 0x10, 0x03, 0x0E, 0x09, 0x00],             0],
  # Negative Gamma Correction
  [0xE1, [0x00, 0x0E, 0x14, 0x03, 0x11, 0x07, 0x31,
          0xC1, 0x48, 0x08, 0x0F, 0x0C, 0x31, 0x36, 0x0F],             0],

  # Display inversion ON (upstream calls esp_lcd_panel_invert_color(panel, true))
  [0x21, [],                                                           0],

  [0x29, [],                                                         100],  # DISPON (display on)
].freeze
```

### Color setup helpers (Task 8 reference)

- `0x2A` CASET (column addr): `[xs_high, xs_low, xe_high, xe_low]`
- `0x2B` RASET (row addr):    `[ys_high, ys_low, ye_high, ye_low]`
- `0x2C` RAMWR: stream `count*2` bytes of RGB565 (big-endian on SPI).
  Upstream sets `swap_bytes=1` in `lvgl_port_display_cfg_t` — i.e. the
  panel expects high byte first per pixel.

## MADCTL rotation map

Memory Access Control (`0x36`) bits:
`MY (D7) | MX (D6) | MV (D5) | ML (D4) | BGR (D3) | MH (D2) | 0 | 0`

CoreS3's ILI9342 uses **BGR pixel order**, so D3 is always set in our values.

| Logical orientation     | Pixels (W×H) | MADCTL  | Bits         | Notes                                            |
|-------------------------|-------------:|---------|--------------|--------------------------------------------------|
| `:landscape`  (default) | 320 × 240    | `0x08`  | BGR=1        | Upstream default (`swap_xy=false, mirror_*=false`) |
| `:portrait`             | 240 × 320    | `0x68`  | MV+MX+BGR    | Swap XY + mirror X (rotate 90° CW)               |
| `:landscape_flip`       | 320 × 240    | `0xC8`  | MY+MX+BGR    | 180° rotation                                    |
| `:portrait_flip`        | 240 × 320    | `0xA8`  | MV+MY+BGR    | Swap XY + mirror Y (rotate 90° CCW)              |

> [!NOTE]
> If on first flash the colors look swapped (red↔blue), clear the BGR bit
> (D3 = 0) — i.e. use `0x00 / 0x60 / 0xC0 / 0xA0`. Upstream uses BGR.

## Source

- Upstream repo: `m5stack/StackChan` (read-only reference)
- Commit: `f8bbb9084d8410194ea3efd5a78b184ee2e3b6d4` (2026-05-07)
- License: MIT (verified Task 2)
- Files:
  - `firmware/main/hal/board/stackchan.cc`
    - `InitializeSpi()` lines 397–407 (SPI3 bus, MOSI=37, SCLK=36)
    - `InitializeIli9342Display()` lines 409–446 (CS=3, DC=35, 40 MHz, mode 2, BGR)
    - `Aw9523::ResetIli9342()` lines 168–175 (reset via AW9523 P1.1 (bit 1 of reg 0x03))
    - `CustomBacklight` lines 129–143 (backlight via AXP2101 PMIC)
  - `firmware/main/hal/board/config.h`
    - `DISPLAY_WIDTH` 320, `DISPLAY_HEIGHT` 240
    - `DISPLAY_SWAP_XY` / `DISPLAY_MIRROR_X` / `DISPLAY_MIRROR_Y` all `false`
    - All direct LCD GPIO macros are `GPIO_NUM_NC` (the live wiring is in
      `stackchan.cc`, not `config.h`)
  - `firmware/main/hal/board/stackchan_display.cc`
    - High-level LVGL/avatar layer; no init bytes here
- Init bytes source: ILI9342C datasheet (Ilitek). The fallback
  `INIT_COMMANDS` sequence above mirrors the init flow used by ESP-IDF's
  `esp_lcd_new_panel_ili9341` (component `esp_lcd`, file
  `components/esp_lcd/src/esp_lcd_panel_ili9341.c`) and the LovyanGFX
  `Panel_ILI9341::init()` reference implementation
  (`lovyan03/LovyanGFX` repo, file
  `src/lgfx/v1/panel/Panel_ILI9341.cpp`). When debugging at hardware
  bring-up (Task 16), compare the actual byte sequence against the
  datasheet command set if init produces no output. Will be
  validated/tuned during Task 16 hardware bring-up.
