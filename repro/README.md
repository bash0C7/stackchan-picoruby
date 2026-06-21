# picoruby-ble: cross-thread mruby heap corruption from `BLE_write_data` on the BTstack task

Reproduction package for an upstream picoruby/picoruby issue. The bug is in
**shared** code (`mrbgems/picoruby-ble/src/mruby/ble.c`, `src/ble.c`), so it is
not specific to any single application. This package isolates it from any
particular board (no LCD/servo/audio/I²C).

> Status: the underlying crash is **confirmed on real hardware** via a full
> application (panic dump below). The minimal standalone scripts here model that
> exact crash; on-device verification of *this minimal form* is the first step
> when filing — see "Verification status".

## Summary

`BLE_write_data` (`src/mruby/ble.c`) is invoked from `att_write_callback`, which
runs on the **BTstack run-loop task**. It allocates mruby objects directly on the
single shared VM:

```c
mrb_value write_value = mrb_str_new(_mrb, (const char *)data, size);
...
queue = mrb_ary_new_capa(_mrb, 4);
mrb_hash_set(_mrb, write_values, key, queue);
mrb_ary_push(_mrb, queue, write_value);
```

`BLE_push_event` similarly calls `mrb_malloc`/`mrb_free` from the BTstack task.

The Ruby VM itself runs on a **different task** (the main task). On a multi-core
or preemptive port (e.g. the ESP32 BTstack port: a dedicated FreeRTOS task,
`ports/esp32/btstack_owner.c` → `xTaskCreate(..., "btstack", ...)`, on a
dual-core SoC) these two tasks call the non-thread-safe mruby allocator/GC
concurrently → heap free-list corruption → a later ordinary allocation faults.

The existing guards are plain `bool`s (not atomic, not real mutexes) and the
original code already flags this:

```c
/* Workaround: To avoid deadlock
 * TODO: Maybe we need a critical section instead of these simple mutex */
static bool packet_mutex = false;
static bool write_values_mutex = false;
```

They also do not protect the main task's unrelated allocations/GC at all, so even
a correct lock around the queue bookkeeping would not prevent an allocator/GC
collision.

Only a high write-without-response rate exposes it (one `BLE_write_data` per
inbound chunk, hundreds per second). Low-rate writes (a few commands) never hit
it — which is why it stays latent until something streams data in (audio, file
transfer, etc.).

## Environment (confirmed)

- Target: ESP32-S3 dual-core (M5Stack CoreS3), 8 MB PSRAM
- ESP-IDF v5.4.2, BTstack ESP32 port (BLE-only), picoruby (mruby VM)
- picoruby-ble peripheral role, Nordic UART Service

## Files

- `ble_race_peripheral.rb` — minimal picoruby-ble peripheral. Drains inbound
  writes and churns the main-task allocator. Advertises as `BleRaceRepro`.
- `flood_rx.rb` — a BLE central (macOS / rb-corebluetooth-mac) that floods
  write-without-response to the RX characteristic. Any flooding central works.

## Steps

1. Flash a picoruby build that includes picoruby-ble; run `ble_race_peripheral.rb`.
2. Attach a serial monitor to capture a panic.
3. Run a flooding central, e.g. `flood_rx.rb`
   (`cd pc/stackchan && bundle exec ruby ../../repro/flood_rx.rb`).
4. Watch the peripheral's serial output.

- Buggy build: `Guru Meditation Error ... (StoreProhibited)` within seconds, with
  a backtrace through the mruby allocator.
- Fixed build: no crash; `rx_bytes=` increases indefinitely under sustained flood.

## Evidence — real panic dump (confirmed)

Captured from a full application doing the same thing (streaming an audio clip
over write-without-response). `idf_monitor` resolved the symbols:

```
Guru Meditation Error: Core 0 panic'ed (StoreProhibited). Exception was unhandled.
PC: 0x42042cc2 est_malloc   EXCCAUSE 0x1d (StoreProhibited)   EXCVADDR 0xfdfcfd04
A11 0xfdfcfcfc   (corrupted free-list pointer)
Backtrace:
  est_malloc <- est_realloc <- mrb_basic_alloc_func <- mrb_realloc_simple <- mrb_realloc
  <- ary_expand_capa <- mrb_ary_push <- mrb_ary_push_m <- mrb_vm_exec
  <- execute_task_vm (task.c) <- mrb_protect_error <- execute_task (task.c)
  <- task_run_body (task.c) <- mrb_task_run <- picoruby_esp32 (picoruby-esp32.c:116)
  <- app_main (main.c:5) <- main_task <- vPortTaskWrapper
```

The fault is an ordinary `Array#push` → `ary_expand_capa` → `mrb_realloc` whose
allocator writes through a corrupted free-list pointer (`0xfdfcfcfc`), i.e. the
mruby heap was already corrupted by concurrent allocation from the BTstack task.
It is volume-dependent: a ~12 s (≈96 KB) clip survived, a ~15 s clip rebooted.

## Verification status

- Confirmed: the crash above, reproduced reliably on ESP32-S3 by streaming a
  long clip over write-without-response while the Ruby VM is active.
- Pending: an on-device run of the *minimal* `ble_race_peripheral.rb` +
  `flood_rx.rb` form (it models the same code path; verifying it makes a clean,
  app-independent repro for maintainers).
- RP2040 / Pico W: the offending code is shared, but reliable manifestation
  depends on the port's `async_context` model (a preemptive
  `threadsafe_background` context would race; a cooperative `poll` context would
  not). Not verified on RP2040.

## Suggested fix direction

Never touch the mruby VM from the BTstack-task callbacks. In `BLE_write_data` /
`BLE_push_event`, copy the bytes into a plain C FIFO (`malloc`/`free`; the host
heap is thread-safe) guarded by a real lock; build the mruby `String` only on the
main task in `pop_write_value` / `pop_packet` (outside the lock). The lock
primitive is port-provided (FreeRTOS recursive mutex on ESP32; a
`critical_section_t` / async-context lock on RP2040). Wrapping only the mruby
allocator function is insufficient — a GC triggered on the BTstack task still
races main-task object mutation.
