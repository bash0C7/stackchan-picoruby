# AOT kernels (spinel → suppify)

`kernels/*.rb` is plain Ruby, tested as such by `aot/test` on the host VM (the
device and aw88298 suites also run it in place of the compiled kernels). A build
compiles it ahead of time with [spinel](https://github.com/matz/spinel) and wraps it into
one PicoRuby mrbgem with [suppify](https://github.com/bash0C7/suppify). Types are
inline RBS (`#:`) on each public top-level `def`; helpers are `private`.

| Kernel | Called as | Used by |
|---|---|---|
| `ulaw_decode(String) -> String` | `Multicore.spawn(:ulaw_decode, chunk)` on core 1 | `AW88298#play_ulaw` |
| `glyph16(w, fg, bg, r0..r15) -> String` | Kernel method, core 0 | `ILI9342#blit_glyph` (16-row glyphs) |

`ulaw_decode` runs on core 1 so the decode of one chunk overlaps the blocking
I2S write of the previous one. A kernel reply must fit picoruby-multicore's
4096-byte buffer, so `play_ulaw` sends 2046 mu-law bytes per call. Direct calls
keep 0x00 bytes in String arguments: the binding publishes each argument's
length with `<lib>_set_arg_len`.

**One runtime, one core at a time.** Every kernel shares one spinel runtime
(one suppify library, so the firmware carries one set of runtime tables). It is not
thread-safe, so no kernel runs on core 0 while core 1 is inside one. That holds
because `play_ulaw` is the only multicore caller and does nothing but I2S writes
while core 1 decodes; drawing never runs during playback.

## Build

```
tools/aot/setup.sh                    # suppify @ suppify.pin, spinel @ suppify's spinel.pin, picoruby-multicore @ multicore.pin
tools/aot/kernels_build.rb esp32      # build/aot/esp32/{gems/picoruby-stackchan_aot,picoruby-kernel_registry}
tools/aot/syntax_check_mcu.sh build/aot/esp32/gems/picoruby-stackchan_aot   # seconds; XTENSA_GCC= to pick the compiler
tools/aot_host_vm.sh                  # host VM with the kernels + multicore's pthread port -> build/host-aot
```

`kernels_build.rb esp32` runs `tools/aot/prepare_mcu.sh` on the generated gem:
the spinel runtime assumes a 64-bit POSIX host, so for xtensa/newlib it

- shrinks the runtime's static tables with `-D` (unpatched they are about 850 KB of `.bss`),
- replaces the mmap slab allocator with malloc (`mcu-shim/sp_slab_malloc.c`),
- drops `sp_net` / `sp_process` / `sp_process_status` and compiles the rest against the declaration-only headers in `mcu-shim/`,
- lowers the first GC triggers below the size of the dynamic heap.

`SP_GC_STACK_MAX` (256) is the one table that fails silently when it overflows:
it drops GC roots. Re-check it when a kernel grows.

## Benchmarks (host)

```
cat mrbgems/picoruby-aw88298/mrblib/aw88298.rb bench/aot_ab.rb > build/aot_ab.rb
build/host-aot/bin/picoruby build/aot_ab.rb
```

Each pair is checked for equal bytes before it is timed. Host wall-clock only;
device timings come from `/stackchan-device-trial`.
