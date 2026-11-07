# AOT kernels (spinel → suppify)

`kernels/*.rb` is plain Ruby, tested as such by `aot/test` on the host VM (the
device and aw88298 suites also run it in place of the compiled kernels). A build
compiles it ahead of time with [spinel](https://github.com/bash0C7/spinel) and wraps it into
one PicoRuby mrbgem with [suppify](https://github.com/bash0C7/suppify). The kernels are
`def self.` methods of `module StackchanAot`, typed with inline RBS (`#:`). The entries are
listed in `tools/aot/kernels_build.rb` (`ENTRIES`); other methods stay inside the kernel.

| Kernel | Called as | Used by |
|---|---|---|
| `StackchanAot.ulaw_decode(String) -> String` | `Multicore.spawn(:ulaw_decode, chunk)` on core 1 | `AW88298#play_ulaw` |
| `StackchanAot.glyph16(w, fg, bg, r0..r15) -> String` | `Kernel#glyph16` (robot gem), core 0 | `ILI9342#blit_glyph` (16-row glyphs) |

`ulaw_decode` runs on core 1 so the decode of one chunk overlaps the blocking
I2S write of the previous one. A kernel reply must fit picoruby-multicore's
4096-byte buffer, so `play_ulaw` sends 2046 mu-law bytes per call. Strings cross
the C contract with their length, so 0x00 bytes survive.

**One instance per caller.** suppify generates the gem with `--table multicore_kernels`:
the VM calls its own instance (`StackchanAot.*`), and picoruby-multicore's worker on
core 1 looks kernels up in worker 1's table, which is a second copy of the kernels
and the spinel runtime. The two run at the same time. Each instance takes one call at a
time, and the two share only libc: stdout among it, which the runtime writes without a lock
on this board, so a kernel does not print.

## Build

```
tools/aot/setup.sh                    # suppify @ suppify.pin, spinel @ suppify's spinel.pin (bash0C7/spinel), picoruby-multicore @ multicore.pin
tools/aot/kernels_build.rb esp32      # build/aot/esp32/gems/picoruby-stackchan_aot (--cc xtensa-esp32s3-elf-gcc)
tools/aot/syntax_check_mcu.sh build/aot/esp32/gems/picoruby-stackchan_aot   # seconds; XTENSA_GCC= to pick the compiler
tools/aot_host_vm.sh                  # host VM with the kernels + multicore's pthread port -> build/host-aot
```

`kernels_build.rb esp32` passes `--cc` with the ESP32-S3 compiler (`XTENSA_GCC=`, else the
newest `xtensa-esp32s3-elf-gcc` under `IDF_TOOLS_PATH` or `~/.espressif`). spinel takes the
Integer width from it and reports the board's build (`--print-build`), which suppify puts in the
gem: the defines (`SP_NO_SIGNALS`, `SP_NO_TERMIOS`, …), spinel's `lib/newlib` headers as
`src/newlib` first on the include path, and `-include sp_newlib_config.h`, which sizes the
runtime's tables and first GC triggers for a small heap (spinel's `docs/newlib.md`). The firmware
build compiles `ports/esp32/multicore.c` from the gem list.

## Benchmarks (host)

```
cat mrbgems/picoruby-aw88298/mrblib/aw88298.rb bench/aot_ab.rb > build/aot_ab.rb
build/host-aot/bin/picoruby build/aot_ab.rb
```

Each pair is checked for equal bytes before it is timed. Host wall-clock only;
device timings come from `/stackchan-device-acceptance`.
