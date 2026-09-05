# rigor

[rigor](https://github.com/rigortype/rigor) is a type-inference static analyzer for Ruby.
It runs on the host over `app/ lib/ mrbgems/ pc/ test/ test-host/`.

## Why it is not in the Gemfile

`rigortype` requires `prism >= 1.0`. This repo is pinned to `prism ~> 0.30`, the version
picoruby vendors and `lib/ruby_class_extract.rb` parses against. Bundler cannot resolve
both, so rigor gets its own gemset under `vendor/rigor-tool/` (gitignored) and never enters
`Gemfile`. `rake rigor:setup` installs it; `RIGOR_VERSION` pins which one.

Anything that shells out to rigor must drop the bundler environment first — `BUNDLE_GEMFILE`
and `RUBYOPT=-rbundler/setup` survive into the child and make it resolve this repo's Gemfile
against the tool gemset, which aborts with `Bundler::GemNotFound`. The Rakefile's `unbundled`
helper does this.

## Tasks

| Task | Does |
|---|---|
| `rake rigor:check` | Fail on any diagnostic not in `rigor.baseline.json`. `rake test` depends on it. |
| `rake rigor:all` | Print every current diagnostic, snapshot or not. |
| `rake rigor:snapshot` | Rewrite `rigor.baseline.json` from the current diagnostics. |
| `rake rigor:setup` | Install the tool gemset. Idempotent; the other tasks depend on it. |

## The snapshot

`rigor.baseline.json` freezes the diagnostics that exist today so `rigor:check` reports only
what is new. Regenerate it with `rake rigor:snapshot` **only** after reading what changed —
the point of the file is that a new diagnostic has to be looked at, not absorbed.

rigor emits absolute paths for source diagnostics and matches `diff` on the raw string, so
`rigor:snapshot` strips the repo root before writing and `rigor:check` puts it back into a
temp copy. The committed file therefore survives a different checkout.

A snapshot entry is not an accepted defect. Of the 22 frozen entries, all 8
`flow.always-truthy-condition` are false positives from rigor 0.3.7 itself, in three shapes:

- **`String#<<` / `#concat` do not invalidate the tracked literal.** `s = +"a"; s << x` leaves
  `s` folded to `"a"`, so every later `s.include?(…)` folds too. Array and Hash mutation are
  handled correctly; String is not. This is what silences the whole `while` body in
  `lib/deploy/picomodem.rb#await_shell` and surfaces at line 153.
- **An `attr_accessor`-generated writer does not count as an assignment to the ivar.** The
  standard `cb = @callback; cb.call(…) if cb` folds to always-falsey. A hand-written
  `def foo=` is handled correctly. Three entries in `pc/`, three more in `test/`.
- **A variable captured by a Proc keeps its definition-site value** even when the Proc mutates
  it, so a fake clock built from `reads.shift` folds. One entry in `test-host/`.

The other 14 are not false positives.

**Five are the test fakes not honouring the BLE contract**, and they exist in the snapshot
only because picoruby's own RBS is loaded — nothing host-side could have caught them.
`test/pc/stubs.rb` returns the value of `@writes << [...]` from three methods that
`BLE::Central` declares as `-> bool` / `-> Integer` / `-> Integer`, and its
`Utils.little_endian_to_int16` dereferences an argument picoruby declares as `String | nil`.
A fake that diverges from the device contract is the failure mode the host suite is
structurally blind to. **These are worth fixing; they are frozen, not accepted.**

Seven `call.possible-nil-receiver` name receivers that really are nullable in RBS —
`String#unpack1`, `String#byteslice`, a `synthesize` that returns nil on timeout, a
`rescue`-assigned local read after the block — and that the code relies on being non-nil
without saying so. One `def.ivar-write-mismatch` observes, correctly, that
`@current_face_class` holds more than one `Face` subclass; that is the design, and declaring
the union would settle it. One is an info about gems with no RBS.

## Signatures

`signature_paths` loads picoruby's own RBS for the peripherals `app/` and `mrbgems/` name, so
`BLE`, `I2C`, `GPIO`, `SPI`, `UART` and `Machine` resolve instead of reading `Dynamic`. This is
also the mechanism by which a picoruby bump becomes a `rigor:check` diff — a renamed method or a
changed return type shows up here rather than in a grep.

Two constraints on that list, both learned by hitting them:

- **Never point it at the whole `mrbgems` tree.** picoruby reimplements parts of the stdlib, so
  `picoruby-base64/sig/base64.rbs` redeclares the `Base64` that rbs ships. One such collision
  raises `RBS::DuplicatedDeclarationError` and collapses the entire environment to nil —
  `RBS classes available: 0`, every type reads `Dynamic[top]`, and the run reports EMPTY rather
  than clean.
- **The per-gem sig files are not self-contained.** `picoruby-uart/sig/uart.rbs` opens with
  `include IRQ`, declared over in `picoruby-irq`. Loading uart without irq leaves `UART` unbuilt
  and silently Dynamic.

The paths live under the gitignored `vendor/` checkout, so `rake vendor:setup` must have run.
That costs nothing: `rake test` already needs the same tree to build the picotest VM.

The LCD, PY32 and servo gems are fetched by the firmware build into `build/repos/`, not
`vendor/`, so their signatures are not loaded and `ILI9342` still types as Dynamic.
