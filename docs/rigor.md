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
| `rake rigor:check` | Fail on any diagnostic not in `rigor.baseline.json`. `rake test` depends on it. Aborts first if any `signature_paths` entry resolves to nothing — `rigor diff` prints only the diff, so without that check a tree that skipped `rake vendor:setup` analyses every picoruby type as Dynamic and still reports 0 new. |
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

A snapshot entry is not an accepted defect. Of the 17 frozen entries, all 8
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

The other 9 are not false positives.

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

The picoruby paths live under the gitignored `vendor/` checkout, so `rake vendor:setup` must
have run. That costs nothing: `rake test` already needs the same tree to build the picotest VM.

This repo's own four gems carry hand-written `sig/` in the upstream picoruby layout
(`mrbgems/picoruby-<gem>/sig/*.rbs`), also listed in `signature_paths`. They are hand-written
rather than generated: `rigor sig-gen` emits only the methods it can fully type and says
nothing about the rest — 5 of `frame_codec.rb`'s 10 — writes them to a mirrored
`sig/<source path>.rbs` instead of the gem's own `sig/`, and with `--params=observed` narrows a
parameter to whatever one call site happened to pass (`def face: (:smile)`). Useful as a
cross-check, not as the artifact.

Each gem's `sig/` is self-contained. The collaborators the constructors take — the I2C bus,
the I2S sink, the PY32 expander — are declared as interfaces scoped inside the class
(`Si12T::_Bus`) rather than as `I2C`, so the host fakes satisfy them structurally and no gem's
signatures depend on another gem's being loaded.

The LCD, PY32 and servo gems are fetched by the firmware build into `build/repos/`, not
`vendor/`, so their signatures are not loaded and `ILI9342` still types as Dynamic.
