---
name: stackchan-docs-sync
description: Bring the `#:` signatures, method descriptions, generated sig/generated RBS, mrbgem READMEs and docs/api up to date after Ruby code changed. Use after editing any .rb under mrbgems/, lib/, pc/, aot/kernels/, acceptance/ or tools/.
---

The source comments are the single source of types and docs. `rake docs` runs rbs-inline over the Ruby files, writes RBS to `sig/generated` (`mrbgems/<gem>/sig/generated` for gems), and renders the API sections of `mrbgems/*/README.md` and `docs/api/*.md` from that RBS. `rake test` runs `docs:check` first.

1. `bundle exec rake docs:check` lists every method without a description, every method without a `#:` signature, every attr without a type, a missing gem README, and every generated file that is out of date. `ONLY=<path substring>` filters the list.
2. For each reported item, read the code and its callers and write the annotation directly above the declaration:
   ```ruby
   # Sends one frame and waits for the ACK.
   #: (String frame, ?Integer timeout_ms) -> Hash[Symbol, untyped]
   def send_frame(frame, timeout_ms = 3000)
   ```
   - `attr_reader :state #: Symbol` takes a trailing type; instance variables take `# @rbs @name: Type`; aliases and interfaces go in a `# @rbs!` block.
   - A changed def keeps its `#:` signature in step with the parameters (count, keyword names, optional `?`, block `{ }`, return type) and its description in step with the behavior.
   - Add only comment lines. Use `untyped` only when the type cannot be known.
3. A new gem under `mrbgems/` needs a hand-written `README.md` (title, one summary line, `## Usage`); the generator appends the API section between its markers.
4. `bundle exec rake docs` regenerates `sig/generated` and the Markdown; commit them with the source change.
5. `bundle exec rake docs:validate` checks the generated RBS with `rbs`.

Report: the problem count before and after, which files got annotations, and whether `docs:check` ends with `docs: ok`.
