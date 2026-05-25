# Handoff 2026-05-21: Test harness Ruby::Box isolation complete

## TL;DR for next session

`feat/test-harness-ruby-box-isolation` branch lands `rake test_isolated` (per-file Ruby::Box) for **all 6 suites**; legacy `rake test` preserved across every suite. **310 tests / 595 assertions / 0 failures** in both modes (post-fix regression test counted). Branch ready for merge.

Next session: resume calibration plan on `feat/servo-tuning-and-test-fix` (Tasks 15-17: `run_align_only` / `run_full_calibrate` workflow runners + CLI wire-up), then HITL Task 23 on real device.

## Branch state

- Branch: `feat/test-harness-ruby-box-isolation`
- HEAD: `302e02a` (`fix(test-harness): box-side script interpolation now produces real failure text`)
- Working tree: clean
- Branched from: `dd2de99` (calibration helpers partial commit) on `feat/servo-tuning-and-test-fix`

### Commit list (newest first, 12 commits ahead of branch base parent)

```
302e02a fix(test-harness): box-side script interpolation now produces real failure text
2fbd943 docs(handoff): test harness Ruby::Box isolation branch complete
a864a86 docs(test-harness): rollback rehearsal verified, per-suite revert works
48f3271 feat(test-harness): isolate root suite tests via Ruby::Box (verification only)
801087b feat(test-harness): isolate stackchan-protocol tests via Ruby::Box
5b906ea feat(test-harness): isolate ili9342 tests via Ruby::Box
dc6ae2c feat(test-harness): isolate py32-io-expander tests via Ruby::Box
8707bbe feat(test-harness): isolate stackchan-led tests via Ruby::Box
dad6e51 feat(test-harness): Ruby::Box per-file isolation runner + ble-client wiring
3ecaa77 docs(plan): test harness Ruby::Box isolation implementation plan (2026-05-21)
b010724 docs(spec): test harness Ruby::Box isolation design (2026-05-21)
dd2de99 feat(ble-client): calibration helpers — median / anchors / format / sample_pose
```

## Per-suite outcome

| suite | isolated status | tests (legacy / isolated) | assertions (legacy / isolated) |
|---|---|---|---|
| `test/` (root) | ✅ isolated | 71 / 71 | 102 / 102 |
| `pc/stackchan-ble-client` | ✅ isolated | 100 / 100 | 183 / 183 |
| `mrbgems/picoruby-stackchan-led` | ✅ isolated | 47 / 47 | 159 / 159 |
| `mrbgems/picoruby-py32-io-expander` | ✅ isolated | 33 / 33 | 52 / 52 |
| `mrbgems/picoruby-ili9342` | ✅ isolated | 24 / 24 | 42 / 42 |
| `mrbgems/picoruby-stackchan-protocol` | ✅ isolated | 35 / 35 | 57 / 57 |
| **TOTAL** | | **310 / 310** | **595 / 595** |

Root suite count went from 70→71 (and 98→102 assertions) when the post-final-review fix commit (`302e02a`) added a regression test for the box-side interpolation bug.

## DoD checklist (spec §Section 6)

- [x] **#1**: `lib/test_isolator/{runner_main,box_runner,result_aggregator}.rb` implemented + tested (`test/test_isolator/*_test.rb` green)
- [x] **#2**: root `Rakefile` `:test_isolated` task runs (Phase 1 commit `dad6e51`)
- [x] **#3-5**: per-suite isolated green (5 suites + root, all 0 failures, counts match legacy)
- [x] **#6**: rollback procedure in commit messages (every Phase 2-5 commit has `Rollback: ...` line)
- [x] **#7**: CLAUDE.md cross-ref ("Box-isolated test runner (experimental)" section, plus Phase 6 + Phase 7 verification notes)
- [x] **#8**: rollback rehearsal verified (Phase 7 commit `a864a86`) — reverting stackchan-led commit on transient HEAD removed only that suite's `:test_isolated` task while legacy and other suites' isolated remained functional

All 8 DoD items: ✅

## Key implementation findings

Captured in memory `project_ruby_box_test_unit_compat_findings`:

1. **`Test::Unit::TestCase.descendants` does not exist** in test-unit 3.7 — correct method is `subclasses`. Initial plan had this as a bug; implementer corrected.
2. **Subclass registries are box-local** — `subclasses` called from parent returns empty after `box.require(file)`. Therefore the test-collection runner must execute INSIDE the box.
3. **Implementation uses Ruby::Box code-string-execution API + JSON marshaling** to bridge results back to parent. `$LOAD_PATH` is injected into the box before the inner `require` so gems resolve.
4. **`Test::Unit::UI::Console::TestRunner.new(suite).start`** works inside a box; suppress via `$stdout = StringIO.new` with `ensure`.
5. **Plan template path bug**: `File.expand_path("../../..", __dir__)` from mrbgem Rakefile expands to project parent; correct is `../..` (2 levels). Implementer corrected for Phase 2; subsequent phases used corrected form.

## Rollback options (always available)

- **L1 / branch廃棄**: `git checkout main && git branch -D feat/test-harness-ruby-box-isolation` (calibration work survives on `feat/servo-tuning-and-test-fix`)
- **L2 / suite 単独 revert**: `git revert <suite-commit-sha>` — only that suite reverts to legacy-only
- **L3 / runtime fallback**: `bundle exec rake test` (envvar absent → box disabled → legacy behavior) — always works, no code changes needed

## Next session

1. `git checkout feat/servo-tuning-and-test-fix` to return to calibration work
2. Resume calibration plan Tasks 15-17 (run_align_only / run_full_calibrate / CLI wire-up)
3. HITL Task 23 on real device (operator manual cal flow)
4. Calibration plan task list (#15-25) still alive in TaskList; HEAD on that branch is `dd2de99`

This branch can be merged to main now or after the calibration plan completes — either order is safe (no file overlap between calibration and test harness work).
