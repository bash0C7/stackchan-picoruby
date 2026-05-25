# Test Harness Ruby::Box Isolation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add per-test-file Ruby::Box isolation runner (`rake test_isolated`) that loads each test file into its own Ruby::Box, preserving the existing `rake test` legacy path. Migrate 6 suites one commit at a time so each step is independently revertable.

**Architecture:** New `lib/test_isolator/{box_runner,result_aggregator,runner_main}.rb` invoked via `sh "RUBY_BOX=1 bundle exec ruby ..."` from each suite's Rakefile. Per-file box uses `Ruby::Box.new` + `box.require(file)`. Test counting via `Test::Unit::TestCase.descendants` snapshot diff (works regardless of whether descendants registry crosses box boundaries). Legacy `rake test` continues to function with `RUBY_BOX` unset.

**Tech Stack:** Ruby 4.0.3 (Box experimental), `test-unit` 3.7, `rake`, Bundler. Each suite has its own Gemfile/bundle.

**Spec reference:** `docs/superpowers/specs/2026-05-21-test-harness-ruby-box-isolation-design.md` (commit `b010724`)

**Branch:** `feat/test-harness-ruby-box-isolation` (already created from `dd2de99` partial calibration commit)

---

## File Map

| File | Action | Why |
|---|---|---|
| `lib/test_isolator/box_runner.rb` | **create** | per-file Ruby::Box runner with descendants-diff counting |
| `lib/test_isolator/result_aggregator.rb` | **create** | aggregate per-file results into unified summary + exit code |
| `lib/test_isolator/runner_main.rb` | **create** | CLI entry: parse argv, dispatch each file, emit report |
| `test/test_isolator/fixtures/isolation_a_test.rb` | **create** | fixture file A — defines `IsolationA` constant, asserts `IsolationB` invisible |
| `test/test_isolator/fixtures/isolation_b_test.rb` | **create** | fixture file B — defines `IsolationB`, asserts `IsolationA` invisible |
| `test/test_isolator/fixtures/passing_test.rb` | **create** | trivial all-pass fixture for counting tests |
| `test/test_isolator/fixtures/failing_test.rb` | **create** | trivial fixture with 1 failure for failure-count test |
| `test/test_isolator/box_runner_test.rb` | **create** | unit test for box_runner via subprocess (RUBY_BOX=1) |
| `test/test_isolator/result_aggregator_test.rb` | **create** | unit test for aggregator (pure Ruby, no box) |
| `test/test_isolator/runner_main_test.rb` | **create** | end-to-end test for runner_main via subprocess |
| `Rakefile` (root) | modify | add `:test_isolated` task + exclude `test/test_isolator/fixtures` from `:test` (fixtures are inputs, not tests) |
| `pc/stackchan-ble-client/Rakefile` | modify | add `:test_isolated` task for suite |
| `mrbgems/picoruby-stackchan-led/Rakefile` | modify | add `:test_isolated` |
| `mrbgems/picoruby-py32-io-expander/Rakefile` | modify | add `:test_isolated` |
| `mrbgems/picoruby-ili9342/Rakefile` | modify | add `:test_isolated` |
| `mrbgems/picoruby-stackchan-protocol/Rakefile` | modify | add `:test_isolated` |
| `CLAUDE.md` | modify | 1-line cross-ref to test_isolator spec |

---

## Phase 1 — Runner foundation + ble-client wiring (commit 1)

### Task 1.1: Create fixture directory + 2 isolation fixtures + 2 trivial fixtures

**Files:**
- Create: `test/test_isolator/fixtures/isolation_a_test.rb`
- Create: `test/test_isolator/fixtures/isolation_b_test.rb`
- Create: `test/test_isolator/fixtures/passing_test.rb`
- Create: `test/test_isolator/fixtures/failing_test.rb`

- [ ] **Step 1: Create fixture A**

Write `test/test_isolator/fixtures/isolation_a_test.rb`:

```ruby
require "test-unit"

class IsolationA
  MARKER = "A_MARKER"
end

class IsolationATest < Test::Unit::TestCase
  def test_a_defined_here
    assert_equal "A_MARKER", IsolationA::MARKER
  end

  def test_b_not_visible_in_this_box
    assert_false Object.const_defined?(:IsolationB),
      "IsolationB should NOT be visible from box A — if it is, file isolation is broken"
  end
end
```

- [ ] **Step 2: Create fixture B**

Write `test/test_isolator/fixtures/isolation_b_test.rb`:

```ruby
require "test-unit"

class IsolationB
  MARKER = "B_MARKER"
end

class IsolationBTest < Test::Unit::TestCase
  def test_b_defined_here
    assert_equal "B_MARKER", IsolationB::MARKER
  end

  def test_a_not_visible_in_this_box
    assert_false Object.const_defined?(:IsolationA),
      "IsolationA should NOT be visible from box B — if it is, file isolation is broken"
  end
end
```

- [ ] **Step 3: Create trivial passing fixture**

Write `test/test_isolator/fixtures/passing_test.rb`:

```ruby
require "test-unit"

class PassingTest < Test::Unit::TestCase
  def test_one_plus_one
    assert_equal 2, 1 + 1
  end

  def test_string_concat
    assert_equal "ab", "a" + "b"
  end
end
```

- [ ] **Step 4: Create trivial failing fixture**

Write `test/test_isolator/fixtures/failing_test.rb`:

```ruby
require "test-unit"

class FailingTest < Test::Unit::TestCase
  def test_will_fail
    assert_equal 1, 2
  end

  def test_will_pass
    assert_equal 1, 1
  end
end
```

No verification step — fixtures are inputs to the runner. They will be exercised in Task 1.6.

### Task 1.2: Failing unit test for box_runner (`box_runner_test.rb`)

**Files:**
- Create: `test/test_isolator/box_runner_test.rb`

- [ ] **Step 1: Write failing test**

```ruby
require "test-unit"
require "open3"

# Shells out to a subprocess that has RUBY_BOX=1 set so the actual
# Ruby::Box invocation happens in the child. The test itself runs in
# the regular legacy process.
class TestBoxRunner < Test::Unit::TestCase
  FIXTURES_DIR = File.expand_path("fixtures", __dir__)
  REPO_ROOT    = File.expand_path("../..", __dir__)

  def run_box_runner_cli(*fixture_basenames)
    files = fixture_basenames.map { |b| File.join(FIXTURES_DIR, b) }
    cmd = [
      {"RUBY_BOX" => "1"},
      "bundle", "exec", "ruby",
      "-I#{REPO_ROOT}/lib",
      "#{REPO_ROOT}/lib/test_isolator/runner_main.rb",
      *files,
    ]
    Open3.capture3(*cmd)
  end

  def test_passing_fixture_reports_passed
    stdout, stderr, status = run_box_runner_cli("passing_test.rb")
    assert_predicate status, :success?, "runner exited non-zero: stderr=#{stderr}"
    assert_match(/passing_test\.rb.*tests=2.*assertions=2.*failures=0/, stdout)
  end

  def test_failing_fixture_reports_failure_and_nonzero_exit
    stdout, stderr, status = run_box_runner_cli("failing_test.rb")
    refute_predicate status, :success?, "runner should exit non-zero when test fails"
    assert_match(/failing_test\.rb.*tests=2.*failures=1/, stdout)
  end

  def test_two_fixtures_isolation_a_and_b_both_pass
    stdout, stderr, status = run_box_runner_cli("isolation_a_test.rb", "isolation_b_test.rb")
    assert_predicate status, :success?,
      "isolation fixtures should both pass when boxes are properly isolated. stderr=#{stderr}, stdout=#{stdout}"
    assert_match(/isolation_a_test\.rb.*tests=2.*failures=0/, stdout)
    assert_match(/isolation_b_test\.rb.*tests=2.*failures=0/, stdout)
  end

  def test_summary_line_present
    stdout, _, _ = run_box_runner_cli("passing_test.rb", "passing_test.rb")
    assert_match(/SUMMARY.*files=2.*tests=4.*failures=0/, stdout)
  end
end
```

- [ ] **Step 2: Run; verify failure (runner_main.rb does not exist yet)**

Run: `cd /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby && bundle exec ruby -Ilib -Itest test/test_isolator/box_runner_test.rb`

Expected: FAIL — `Errno::ENOENT` or similar because `lib/test_isolator/runner_main.rb` does not exist yet.

### Task 1.3: Implement `BoxRunner.run_file` (minimal, single file)

**Files:**
- Create: `lib/test_isolator/box_runner.rb`

- [ ] **Step 1: Implement**

Write `lib/test_isolator/box_runner.rb`:

```ruby
require "test-unit"
require "set"

module TestIsolator
  module BoxRunner
    module_function

    # Run a single test file inside its own Ruby::Box.
    # Returns a result hash:
    #   { file:, test_count:, assertion_count:, failure_count:, error_count:, passed:, output: }
    #
    # Implementation note: Test::Unit::TestCase tracks subclasses via a
    # global Set (descendants registry). We snapshot before box.require
    # and diff after, so we only run TestCase subclasses defined by THIS
    # file regardless of box semantics around shared parent classes.
    def run_file(path)
      unless Ruby::Box.enabled?
        raise "Ruby::Box not enabled — runner_main.rb must be invoked with RUBY_BOX=1"
      end

      before = current_testcase_descendants
      box = Ruby::Box.new
      load_error = nil
      begin
        box.require(File.expand_path(path))
      rescue StandardError, LoadError, ScriptError => e
        load_error = e
      end

      if load_error
        return {
          file: path,
          test_count: 0,
          assertion_count: 0,
          failure_count: 0,
          error_count: 1,
          passed: false,
          output: "[load error] #{load_error.class}: #{load_error.message}",
        }
      end

      new_cases = current_testcase_descendants - before

      suite = Test::Unit::TestSuite.new(path)
      new_cases.each { |tc| suite << tc.suite }

      result = Test::Unit::TestResult.new
      output_lines = []
      result.add_listener(Test::Unit::TestResult::FAULT) do |fault|
        output_lines << "  #{fault.class.name.split('::').last}: #{fault.short_display}"
      end
      suite.run(result) { |_started, _name| } # silent progress

      {
        file: path,
        test_count: result.run_count,
        assertion_count: result.assertion_count,
        failure_count: result.failure_count,
        error_count: result.error_count,
        passed: result.passed?,
        output: output_lines.join("\n"),
      }
    end

    def current_testcase_descendants
      # Test::Unit::TestCase.descendants returns Array in test-unit 3.x.
      # Wrap in Set for diff stability.
      Test::Unit::TestCase.descendants.to_set
    end
  end
end
```

- [ ] **Step 2: No standalone test run yet — covered after runner_main is implemented (Task 1.5–1.6).**

### Task 1.4: Implement `ResultAggregator` with its own tests

**Files:**
- Create: `lib/test_isolator/result_aggregator.rb`
- Create: `test/test_isolator/result_aggregator_test.rb`

- [ ] **Step 1: Write failing test (pure Ruby, no box needed)**

Write `test/test_isolator/result_aggregator_test.rb`:

```ruby
require "test-unit"
$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
require "test_isolator/result_aggregator"

class TestResultAggregator < Test::Unit::TestCase
  def passing
    {
      file: "a_test.rb", test_count: 2, assertion_count: 4,
      failure_count: 0, error_count: 0, passed: true, output: "",
    }
  end

  def failing
    {
      file: "b_test.rb", test_count: 3, assertion_count: 5,
      failure_count: 1, error_count: 0, passed: false, output: "  Failure: ...",
    }
  end

  def test_aggregate_all_passing_returns_zero_exit
    report = TestIsolator::ResultAggregator.aggregate([passing, passing])
    assert_equal 0, report[:exit_code]
    assert_equal 4, report[:totals][:tests]
    assert_equal 8, report[:totals][:assertions]
    assert_equal 0, report[:totals][:failures]
    assert_equal 2, report[:totals][:files]
  end

  def test_aggregate_with_failing_returns_nonzero_exit
    report = TestIsolator::ResultAggregator.aggregate([passing, failing])
    assert_equal 1, report[:exit_code]
    assert_equal 1, report[:totals][:failures]
  end

  def test_render_includes_per_file_lines_and_summary
    text = TestIsolator::ResultAggregator.render([passing, failing])
    assert_match(/a_test\.rb.*tests=2.*assertions=4.*failures=0/, text)
    assert_match(/b_test\.rb.*tests=3.*assertions=5.*failures=1/, text)
    assert_match(/SUMMARY.*files=2.*tests=5.*assertions=9.*failures=1/, text)
  end
end
```

- [ ] **Step 2: Run; verify failure (`uninitialized constant TestIsolator::ResultAggregator`)**

Run: `cd /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby && bundle exec ruby -Ilib -Itest test/test_isolator/result_aggregator_test.rb`

Expected: FAIL with `NameError: uninitialized constant TestIsolator::ResultAggregator`.

- [ ] **Step 3: Implement**

Write `lib/test_isolator/result_aggregator.rb`:

```ruby
module TestIsolator
  module ResultAggregator
    module_function

    def aggregate(per_file_results)
      totals = {
        files:      per_file_results.length,
        tests:      per_file_results.sum { |r| r[:test_count] },
        assertions: per_file_results.sum { |r| r[:assertion_count] },
        failures:   per_file_results.sum { |r| r[:failure_count] },
        errors:     per_file_results.sum { |r| r[:error_count] },
      }
      exit_code = (totals[:failures] + totals[:errors]) > 0 ? 1 : 0
      { totals: totals, per_file: per_file_results, exit_code: exit_code }
    end

    def render(per_file_results)
      report = aggregate(per_file_results)
      lines = per_file_results.map { |r| render_file_line(r) }
      lines << format_summary(report[:totals])
      lines.join("\n")
    end

    def render_file_line(r)
      status = r[:passed] ? "PASS" : "FAIL"
      base = "[#{status}] #{r[:file]}  tests=#{r[:test_count]} assertions=#{r[:assertion_count]} failures=#{r[:failure_count]} errors=#{r[:error_count]}"
      r[:output].to_s.empty? ? base : "#{base}\n#{r[:output]}"
    end

    def format_summary(t)
      "SUMMARY  files=#{t[:files]} tests=#{t[:tests]} assertions=#{t[:assertions]} failures=#{t[:failures]} errors=#{t[:errors]}"
    end
  end
end
```

- [ ] **Step 4: Run; verify PASS**

Run: `cd /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby && bundle exec ruby -Ilib -Itest test/test_isolator/result_aggregator_test.rb`

Expected: 3 tests PASS.

### Task 1.5: Implement `runner_main.rb` CLI entry

**Files:**
- Create: `lib/test_isolator/runner_main.rb`

- [ ] **Step 1: Implement**

Write `lib/test_isolator/runner_main.rb`:

```ruby
#!/usr/bin/env ruby
# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("..", __dir__)

require "test_isolator/box_runner"
require "test_isolator/result_aggregator"

module TestIsolator
  module Main
    module_function

    def run(argv)
      if argv.empty?
        warn "usage: ruby lib/test_isolator/runner_main.rb <test_file> [test_file ...]"
        return 2
      end

      results = argv.map { |path| BoxRunner.run_file(path) }
      report  = ResultAggregator.aggregate(results)
      puts ResultAggregator.render(results)
      report[:exit_code]
    end
  end
end

if $PROGRAM_NAME == __FILE__
  exit TestIsolator::Main.run(ARGV)
end
```

- [ ] **Step 2: Smoke test directly (manual)**

Run from repo root:
```
RUBY_BOX=1 bundle exec ruby -Ilib lib/test_isolator/runner_main.rb test/test_isolator/fixtures/passing_test.rb
```
Expected: stdout includes `[PASS] test/test_isolator/fixtures/passing_test.rb  tests=2 assertions=2 failures=0 errors=0` and `SUMMARY  files=1 tests=2 ...`. Exit code 0.

If the smoke test fails (Ruby::Box not available, test-unit autorun behavior surprising, etc.), STOP and report BLOCKED to controller with error message.

### Task 1.6: Run box_runner_test.rb (verifies full runner pipeline)

- [ ] **Step 1: Run box_runner unit tests**

Run: `cd /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby && bundle exec ruby -Ilib -Itest test/test_isolator/box_runner_test.rb`

Expected: 4 tests PASS. This validates:
- single file passing
- single file failing → nonzero exit
- two fixture files (isolation A & B) — **both pass = box isolation works**
- summary line format

If `test_two_fixtures_isolation_a_and_b_both_pass` FAILS (one file sees the other's constants), STOP and report BLOCKED — Ruby::Box is not isolating constants as expected.

### Task 1.7: Add `:test_isolated` to root Rakefile + exclude fixtures from `:test`

**Files:**
- Modify: `Rakefile` (project root)

- [ ] **Step 1: Read the current `:test` task definition**

```
grep -n "Rake::TestTask" /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/Rakefile
```

Expected: locates the existing `Rake::TestTask.new(:test) do |t| ... end` block.

- [ ] **Step 2: Modify `:test` to exclude fixtures (so legacy `rake test` doesn't try to run fixtures standalone)**

Change the `t.test_files = FileList[...]` line:

```ruby
  t.test_files = FileList['test/**/*_test.rb'].exclude('test/test_isolator/fixtures/**/*')
```

- [ ] **Step 3: Append new `:test_isolated` task**

After the `Rake::TestTask.new(:test) do |t| ... end` block, add:

```ruby
desc "Run tests with Ruby::Box per-file isolation (RUBY_BOX=1)"
task :test_isolated do
  test_files = Dir["test/**/*_test.rb"].reject { |f| f.start_with?("test/test_isolator/fixtures/") }
  abort "No test files found under test/" if test_files.empty?
  runner = File.expand_path("lib/test_isolator/runner_main.rb", __dir__)
  sh({"RUBY_BOX" => "1"}, "bundle", "exec", "ruby", "-I#{File.expand_path('lib', __dir__)}", "-Itest", runner, *test_files)
end
```

- [ ] **Step 4: Verify task exists**

Run: `cd /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby && bundle exec rake -T | grep test_isolated`

Expected: line `rake test_isolated  # Run tests with Ruby::Box per-file isolation (RUBY_BOX=1)`.

- [ ] **Step 5: Verify legacy `rake test` still passes (fixtures excluded)**

Run: `cd /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby && bundle exec rake test`

Expected: legacy root suite green (count may be different from before due to new runner test files being included — that's correct, runner unit tests run under legacy too).

### Task 1.8: Implement `runner_main_test.rb` (end-to-end via rake)

**Files:**
- Create: `test/test_isolator/runner_main_test.rb`

- [ ] **Step 1: Write integration test**

Write `test/test_isolator/runner_main_test.rb`:

```ruby
require "test-unit"
require "open3"

class TestRunnerMainViaRake < Test::Unit::TestCase
  REPO_ROOT = File.expand_path("../..", __dir__)

  def test_runner_passes_when_fixture_passes
    fixture = File.join(REPO_ROOT, "test/test_isolator/fixtures/passing_test.rb")
    cmd = [
      {"RUBY_BOX" => "1"},
      "bundle", "exec", "ruby",
      "-I#{REPO_ROOT}/lib",
      "#{REPO_ROOT}/lib/test_isolator/runner_main.rb",
      fixture,
    ]
    stdout, stderr, status = Open3.capture3(*cmd, chdir: REPO_ROOT)
    assert_predicate status, :success?, "stderr=#{stderr}"
    assert_match(/SUMMARY.*files=1.*failures=0/, stdout)
  end

  def test_runner_exits_nonzero_when_any_file_fails
    fixture = File.join(REPO_ROOT, "test/test_isolator/fixtures/failing_test.rb")
    cmd = [
      {"RUBY_BOX" => "1"},
      "bundle", "exec", "ruby",
      "-I#{REPO_ROOT}/lib",
      "#{REPO_ROOT}/lib/test_isolator/runner_main.rb",
      fixture,
    ]
    _stdout, _stderr, status = Open3.capture3(*cmd, chdir: REPO_ROOT)
    assert_equal 1, status.exitstatus
  end
end
```

- [ ] **Step 2: Run; verify PASS**

Run: `cd /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby && bundle exec ruby -Ilib -Itest test/test_isolator/runner_main_test.rb`

Expected: 2 tests PASS.

### Task 1.9: Verify `bundle exec rake test` (legacy) full suite green

- [ ] **Step 1: Dispatch a haiku subagent to run legacy rake test**

Subagent prompt:
> From `/Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby`, run `bundle exec rake test` foreground with 300000ms timeout. Capture only pass/fail and final test count. Under 100 words.

Expected: full green, test count includes `test/test_isolator/*` (runner unit tests). Failures must be 0.

### Task 1.10: Add `:test_isolated` to ble-client Rakefile

**Files:**
- Modify: `pc/stackchan-ble-client/Rakefile`

- [ ] **Step 1: Read current ble-client Rakefile**

Run: `cat /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/pc/stackchan-ble-client/Rakefile`

Confirm it has `Rake::TestTask.new(:test) do |t| ... end`.

- [ ] **Step 2: Append `:test_isolated` task**

After the existing `Rake::TestTask.new(:test)` block:

```ruby
desc "Run tests with Ruby::Box per-file isolation (RUBY_BOX=1)"
task :test_isolated do
  repo_root = File.expand_path("../..", __dir__)
  test_files = Dir["test/**/*_test.rb"]
  abort "No test files found under test/" if test_files.empty?
  runner = File.join(repo_root, "lib/test_isolator/runner_main.rb")
  sh({"RUBY_BOX" => "1"}, "bundle", "exec", "ruby",
     "-I#{File.join(repo_root, 'lib')}",
     "-I.",
     "-Itest",
     runner, *test_files)
end
```

- [ ] **Step 3: Verify task lists**

Run: `cd /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/pc/stackchan-ble-client && bundle exec rake -T | grep test_isolated`

Expected: `rake test_isolated  # ...`.

### Task 1.11: Verify ble-client `bundle exec rake test` legacy green

- [ ] **Step 1: Run legacy test, capture count**

Run: `cd /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/pc/stackchan-ble-client && bundle exec rake test`

Record the test count from output (something like `100 tests, 183 assertions, 0 failures` from Phase 3a baseline).

### Task 1.12: Verify ble-client `bundle exec rake test_isolated` green with matching count

- [ ] **Step 1: Run isolated test**

Run: `cd /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/pc/stackchan-ble-client && bundle exec rake test_isolated`

Expected: stdout shows one `[PASS]` line per `test/**/*_test.rb` file, ending with `SUMMARY  files=N tests=M assertions=K failures=0 errors=0` matching the legacy count.

- [ ] **Step 2: Confirm test count matches legacy from Task 1.11**

If test count differs:
- If LOWER: some TestCase classes weren't detected (descendants registry quirk). Investigate before commit.
- If HIGHER: duplicate detection (same TestCase loaded twice). Investigate.
- Either way: STOP, report mismatch, do not commit.

If counts match: proceed.

### Task 1.13: Update CLAUDE.md cross-reference

**Files:**
- Modify: `CLAUDE.md` (project root)

- [ ] **Step 1: Add cross-ref line**

Find a logical section (e.g., near "## Ruby Testing" or top of testing section). Append:

```markdown
### Box-isolated test runner (experimental)

`bundle exec rake test_isolated` (vs legacy `rake test`) runs each test file in its own Ruby::Box for cross-file state isolation. Per-suite via each suite's Rakefile. Spec: `docs/superpowers/specs/2026-05-21-test-harness-ruby-box-isolation-design.md`. Legacy `rake test` continues to work (envvar absent → box disabled).
```

If the project has no `## Ruby Testing` section yet, insert near the top of CLAUDE.md after the project description.

- [ ] **Step 2: Confirm CLAUDE.md still parses (informal — just visually check the diff)**

### Task 1.14: COMMIT 1 — runner foundation + ble-client wiring + cross-ref

- [ ] **Step 1: Dispatch general-purpose subagent to commit**

```bash
git status --short
# Expected files (modified or untracked):
#   ?? lib/test_isolator/
#   ?? test/test_isolator/
#   M  Rakefile
#   M  pc/stackchan-ble-client/Rakefile
#   M  CLAUDE.md
```

Stage explicitly (NOT `git add .`):

```bash
git add lib/test_isolator/ \
        test/test_isolator/ \
        Rakefile \
        pc/stackchan-ble-client/Rakefile \
        CLAUDE.md

git commit -m "$(cat <<'EOF'
feat(test-harness): Ruby::Box per-file isolation runner + ble-client wiring

Adds lib/test_isolator/ (box_runner / result_aggregator / runner_main)
that loads each test file into its own Ruby::Box, so cross-file
constant / monkey-patch / $global pollution is structurally
prevented. Per-suite invocation via `bundle exec rake test_isolated`.

Wires up ble-client suite (lightest test_helper, lowest migration
risk) as the first migrated suite. Legacy `rake test` continues to
work via envvar absence -> box disabled.

Spec: docs/superpowers/specs/2026-05-21-test-harness-ruby-box-isolation-design.md

Rollback: `git revert <this-sha>` removes the runner + ble-client
isolated task; legacy `rake test` remains unaffected.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 2: Verify commit**

```bash
git log --oneline -1
git status --short  # should be clean
```

---

## Phase 2 — stackchan-led migration (commit 2)

### Task 2.1: Read suite test_helper

- [ ] **Step 1: Inspect**

Run: `cat /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/mrbgems/picoruby-stackchan-led/test/test_helper.rb`

Note the shim layout: `$LOAD_PATH.unshift`, `class FakePY32` defined at top-level, then `require "stackchan_led"` and `require "stackchan_led/animator"`. The FakePY32 class will be defined per-box (each file's box loads test_helper, defines FakePY32 fresh).

### Task 2.2: Add `:test_isolated` to suite Rakefile

**Files:**
- Modify: `mrbgems/picoruby-stackchan-led/Rakefile`

- [ ] **Step 1: Read current Rakefile to find insertion point**

Run: `cat /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/mrbgems/picoruby-stackchan-led/Rakefile`

- [ ] **Step 2: Append task (same pattern as ble-client)**

After the existing `Rake::TestTask.new(:test)` block:

```ruby
desc "Run tests with Ruby::Box per-file isolation (RUBY_BOX=1)"
task :test_isolated do
  repo_root = File.expand_path("../../..", __dir__)
  test_files = Dir["test/**/*_test.rb"]
  abort "No test files found under test/" if test_files.empty?
  runner = File.join(repo_root, "lib/test_isolator/runner_main.rb")
  sh({"RUBY_BOX" => "1"}, "bundle", "exec", "ruby",
     "-I#{File.join(repo_root, 'lib')}",
     "-I.",
     "-Itest",
     "-Imrblib",
     runner, *test_files)
end
```

Note: `-Imrblib` is added because mrbgem suites have `$LOAD_PATH.unshift File.expand_path("../mrblib", __dir__)` in test_helper; the boxed Ruby process needs this on its initial $LOAD_PATH for `require "stackchan_led"` to resolve.

### Task 2.3: Verify legacy + isolated counts match

- [ ] **Step 1: Run legacy**

Run: `cd /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/mrbgems/picoruby-stackchan-led && bundle exec rake test`

Record test count.

- [ ] **Step 2: Run isolated**

Run: `cd /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/mrbgems/picoruby-stackchan-led && bundle exec rake test_isolated`

- [ ] **Step 3: Compare**

If counts match and `failures=0 errors=0`: proceed to commit.

If counts differ or failures > 0:
- Common cause 1: `require "stackchan_led"` fails inside box because `$LOAD_PATH` differs. Adjust the `-I` flags in the Rakefile task.
- Common cause 2: `FakePY32` redefinition warnings (acceptable, no impact on test count).
- Common cause 3: test-unit class registry quirk under box. STOP and report BLOCKED — escalate to controller.

### Task 2.4: COMMIT 2

- [ ] **Step 1: Commit**

```bash
git add mrbgems/picoruby-stackchan-led/Rakefile
git commit -m "$(cat <<'EOF'
feat(test-harness): isolate stackchan-led tests via Ruby::Box

Each test file in mrbgems/picoruby-stackchan-led/test/ now loads into
its own Ruby::Box, preventing cross-file constant / monkey-patch /
$global pollution within this suite. Run with
`cd mrbgems/picoruby-stackchan-led && bundle exec rake test_isolated`.

Legacy `rake test` continues to work for rollback (RUBY_BOX not set).

Rollback: revert this commit to restore the shared-process test
loading for this suite only; other suites' box isolation remains.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 3 — py32-io-expander migration (commit 3)

### Task 3.1: Read suite test_helper

- [ ] Run: `cat /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/mrbgems/picoruby-py32-io-expander/test/test_helper.rb`

Note: `$LOADED_FEATURES << "i2c"` modifies a $global. In box mode, $globals are isolated per box — so each file's box will independently mark `"i2c"` as loaded. This is fine.

### Task 3.2: Add `:test_isolated` to suite Rakefile

**Files:**
- Modify: `mrbgems/picoruby-py32-io-expander/Rakefile`

- [ ] **Step 1: Append task (identical body to Task 2.2)**

```ruby
desc "Run tests with Ruby::Box per-file isolation (RUBY_BOX=1)"
task :test_isolated do
  repo_root = File.expand_path("../../..", __dir__)
  test_files = Dir["test/**/*_test.rb"]
  abort "No test files found under test/" if test_files.empty?
  runner = File.join(repo_root, "lib/test_isolator/runner_main.rb")
  sh({"RUBY_BOX" => "1"}, "bundle", "exec", "ruby",
     "-I#{File.join(repo_root, 'lib')}",
     "-I.",
     "-Itest",
     "-Imrblib",
     runner, *test_files)
end
```

### Task 3.3: Verify counts match

- [ ] Run legacy: `cd mrbgems/picoruby-py32-io-expander && bundle exec rake test`, record count
- [ ] Run isolated: `cd mrbgems/picoruby-py32-io-expander && bundle exec rake test_isolated`
- [ ] Counts match, failures=0 → commit; else BLOCKED

### Task 3.4: COMMIT 3

- [ ] Same template as Task 2.4 substituting "py32-io-expander" and "FakeI2C + i2c LOADED_FEATURES shim".

---

## Phase 4 — ili9342 migration (commit 4)

### Task 4.1: Read suite test_helper

- [ ] Run: `cat /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/mrbgems/picoruby-ili9342/test/test_helper.rb`

Note: defines `module Machine` (collides with root suite's Machine) and `class SPI/GPIO` at top level. In box mode these are box-local per file → no conflict.

### Task 4.2: Add `:test_isolated` to suite Rakefile

**Files:**
- Modify: `mrbgems/picoruby-ili9342/Rakefile`

- [ ] **Step 1: Append task (identical body to Task 2.2)**

### Task 4.3: Verify counts match

- [ ] Legacy + isolated runs, counts match → proceed.

### Task 4.4: COMMIT 4

- [ ] Same template as Task 2.4 substituting "ili9342" and "Machine module + SPI/GPIO empty class shims".

---

## Phase 5 — stackchan-protocol migration (commit 5)

### Task 5.1: Read suite test_helper

- [ ] Run: `cat /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/mrbgems/picoruby-stackchan-protocol/test/test_helper.rb`

Note: defines `class ILI9342` (root has `module ILI9342`). Box isolation prevents conflict across suites; intra-suite all files load the same `class ILI9342` in their own box, no issue.

### Task 5.2: Add `:test_isolated` to suite Rakefile

**Files:**
- Modify: `mrbgems/picoruby-stackchan-protocol/Rakefile`

- [ ] **Step 1: Append task (identical body to Task 2.2)**

### Task 5.3: Verify counts match

- [ ] Legacy + isolated, counts match.

### Task 5.4: COMMIT 5

- [ ] Same template as Task 2.4 substituting "stackchan-protocol" and "Face / Dispatcher fake_display / fake_stdio / fake_led + ILI9342 class shim".

---

## Phase 6 — root suite migration (commit 6, highest risk)

The root `test/` suite uses `RubyClassExtract` which writes a tempfile and `load`s it to inject `application.rb` class definitions. This is the most complex shim to box-validate.

### Task 6.1: Probe Ruby::Box constant isolation (mirrors RubyClassExtract pattern)

- [ ] **Step 1: Write a probe script that uses box.require with a tempfile (same shape as RubyClassExtract)**

Create `/tmp/box_probe_rce.rb`:

```ruby
require "tempfile"

box = Ruby::Box.new
puts "Box enabled: #{Ruby::Box.enabled?}"
puts "Object const RceProbeClass before: #{Object.const_defined?(:RceProbeClass)}"

tmp = Tempfile.new(["box_probe", ".rb"])
tmp.write(<<~CODE)
  Object.const_set(:RceProbeClass, Class.new)
  puts "Inside box: const_defined? \#{Object.const_defined?(:RceProbeClass)}"
CODE
tmp.close
box.require(tmp.path)

puts "Object const RceProbeClass after (outside box): #{Object.const_defined?(:RceProbeClass)}"
```

- [ ] **Step 2: Run probe**

Run: `RUBY_BOX=1 bundle exec ruby /tmp/box_probe_rce.rb`

Expected: probe prints `Inside box: const_defined? true` and `after (outside box): false`. This confirms box-local constant scoping for the RubyClassExtract-style tempfile pattern.

If outside box also sees `:RceProbeClass`: Ruby::Box's experimental constant isolation may not behave as documented. STOP and report — likely fall back to L2 rollback (root suite stays legacy per spec Out of Scope).

If probe behaves as expected: proceed.

### Task 6.2: Run root suite with isolated runner (no Rakefile changes needed — Task 1.7 already added root :test_isolated)

- [ ] **Step 1: Run isolated against root test suite**

Run: `cd /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby && bundle exec rake test_isolated`

This runs all `test/**/*_test.rb` files (including `test/test_isolator/*` and root suite tests like `test/scervo_test.rb`, `test/face_*_test.rb`, etc.).

- [ ] **Step 2: Capture full output**

Note total counts and any failures. Compare to `bundle exec rake test` (legacy) numbers from Phase 1 verification.

### Task 6.3: Address discrepancies if any

- [ ] **Step 1: If counts match and 0 failures → skip to Task 6.4 (commit).**

- [ ] **Step 2: If failures present, categorize:**
  - **Category A: shim conflict** — file relies on a constant another file's box also defined. Box isolation prevents this; means the test was implicitly depending on cross-file state. Document which file and which constant, propose minimal fix (move shim into the test file's own test_helper or top of file).
  - **Category B: RubyClassExtract tempfile + box** — if `load tmpfile.path` doesn't add to the box's constant table, the extracted classes are inaccessible. Modify `lib/ruby_class_extract.rb` to use `Ruby::Box.current.load(tmpfile.path)` when `Ruby::Box.enabled?`.
  - **Category C: test-unit subclass registration** — extracted classes via `load` should still subclass-register, but verify with `Test::Unit::TestCase.descendants` debug print.

- [ ] **Step 3: For Category B, the simplest fix:**

```ruby
# in lib/ruby_class_extract.rb, replace `load tmpfile.path` with:
if defined?(Ruby::Box) && Ruby::Box.enabled?
  Ruby::Box.current.load(tmpfile.path)
else
  load(tmpfile.path)
end
```

- [ ] **Step 4: Re-run isolated, verify**

- [ ] **Step 5: If still blocked → escalate.** Per spec Section 5 / Section 6 DoD #5, root suite may remain legacy as an acceptable outcome.

### Task 6.4: COMMIT 6

- [ ] **Step 1: If root suite passed isolated:**

Stage and commit (likely just `lib/ruby_class_extract.rb` if Step 3 above was needed; otherwise no new file changes — the root Rakefile already has `:test_isolated` from Task 1.7).

If no file changed in this phase, this is an empty commit. In that case, document the success in a single comment line in CLAUDE.md instead and commit that:

```bash
git add lib/ruby_class_extract.rb CLAUDE.md  # or just CLAUDE.md if no rce change
git commit -m "$(cat <<'EOF'
feat(test-harness): isolate root suite tests via Ruby::Box

Root test/ suite now runs under Ruby::Box per-file isolation via the
existing root `:test_isolated` task (no new Rakefile changes — task
landed in Phase 1). Verified RubyClassExtract.load_classes_from works
inside boxes [if rce modified: by switching to Ruby::Box.current.load
when Ruby::Box.enabled?].

Legacy `rake test` continues to work via envvar absence.

Rollback: revert this commit to restore the shared-process behavior
for root tests; per-suite isolated commits for mrbgems remain.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 2: If root suite cannot be isolated (per spec out-of-scope rule):**

Instead of a feature commit, add a single-line note to CLAUDE.md "Box-isolated test runner" section:
> **Note:** root suite stays on legacy `rake test`; mrbgem + ble-client suites run isolated. See spec §5 (Out of scope).

Commit:

```bash
git add CLAUDE.md
git commit -m "docs(test-harness): note root suite stays legacy (Box compat blocker)

[brief description of what was tried and why root stays legacy]

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
"
```

---

## Phase 7 — Rollback rehearsal (commit 7)

Per spec Section 6 DoD #8: validate that per-suite revert works.

### Task 7.1: Pick a suite for rehearsal (recommend stackchan-led, commit 2)

- [ ] **Step 1: Identify the commit SHA for stackchan-led isolation**

Run: `git log --oneline --grep="stackchan-led tests via Ruby::Box"`

Record the SHA (call it `LED_SHA`).

### Task 7.2: Test the revert + restore flow

- [ ] **Step 1: Save current HEAD**

```bash
git rev-parse HEAD > /tmp/test_harness_rehearsal_head.txt
cat /tmp/test_harness_rehearsal_head.txt
```

- [ ] **Step 2: Revert the suite commit**

```bash
git revert --no-edit <LED_SHA>
```

- [ ] **Step 3: Verify legacy `rake test` for stackchan-led still works**

```
cd mrbgems/picoruby-stackchan-led && bundle exec rake test
```

Expected: green (legacy was always preserved).

- [ ] **Step 4: Verify isolated `rake test_isolated` for stackchan-led FAILS or is missing**

```
cd mrbgems/picoruby-stackchan-led && bundle exec rake test_isolated 2>&1 | head -3
```

Expected: `rake aborted! Don't know how to build task 'test_isolated'`. This proves the revert removed the isolated task for this suite only.

- [ ] **Step 5: Verify another suite's isolated still works (e.g., ble-client)**

```
cd pc/stackchan-ble-client && bundle exec rake test_isolated
```

Expected: green. This proves per-suite isolation in rollback.

- [ ] **Step 6: Restore — reset to recorded HEAD**

```bash
git reset --hard "$(cat /tmp/test_harness_rehearsal_head.txt)"
```

(`reset --hard` is safe here because we're undoing OUR rehearsal revert; no work between us.)

- [ ] **Step 7: Verify HEAD is restored**

```bash
git log --oneline -3
```

Should show the same top 3 commits as before the rehearsal.

### Task 7.3: Document rehearsal outcome in CLAUDE.md

- [ ] **Step 1: Add rehearsal note**

In CLAUDE.md "Box-isolated test runner" section, add:

```markdown
**Rollback verified (2026-05-21):** Reverting a per-suite commit (e.g., `git revert <SHA>`) removes only that suite's `:test_isolated` task; other suites' isolation and legacy `rake test` remain functional. See plan §Phase 7.
```

### Task 7.4: COMMIT 7

- [ ] **Step 1: Commit the doc note**

```bash
git add CLAUDE.md
git commit -m "$(cat <<'EOF'
docs(test-harness): rollback rehearsal verified, per-suite revert works

Validated spec §6 DoD #8: reverting one suite's box-isolation commit
removes only that suite's :test_isolated task while preserving
legacy rake test and other suites' isolated tasks. See plan Phase 7
for procedure.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 8 — Final DoD verify + handoff (commit 8)

### Task 8.1: Run full host test suites (legacy + isolated)

- [ ] **Step 1: Dispatch haiku subagent to run all suite combinations**

Subagent prompt:
> From `/Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby`, run sequentially with 300000ms timeout each. Capture only pass/fail and final test count per command. Under 200 words total.
>
> 1. `bundle exec rake test` (root, legacy)
> 2. `bundle exec rake test_isolated` (root, isolated)
> 3. `cd pc/stackchan-ble-client && bundle exec rake test && bundle exec rake test_isolated`
> 4. `cd mrbgems/picoruby-stackchan-led && bundle exec rake test && bundle exec rake test_isolated`
> 5. `cd mrbgems/picoruby-py32-io-expander && bundle exec rake test && bundle exec rake test_isolated`
> 6. `cd mrbgems/picoruby-ili9342 && bundle exec rake test && bundle exec rake test_isolated`
> 7. `cd mrbgems/picoruby-stackchan-protocol && bundle exec rake test && bundle exec rake test_isolated`
>
> Report: per-command suite name, test count, failures. If any isolated count differs from legacy, report explicitly.

Expected: all green; isolated counts match legacy (with the possible exception of root suite if Phase 6 went legacy-only fallback).

### Task 8.2: Write handoff doc

**Files:**
- Create: `docs/superpowers/handoff-2026-05-21-test-harness-isolation-complete.md`

- [ ] **Step 1: Write doc**

Template (implementer fills in bracketed values from Task 8.1):

```markdown
# Handoff 2026-05-21: Test harness Ruby::Box isolation complete

## TL;DR for next session

`feat/test-harness-ruby-box-isolation` branch lands `rake test_isolated`
(per-file Ruby::Box) for [N] of 6 suites; legacy `rake test` preserved.
Next session: merge to main (PR open) and resume calibration plan
Tasks 15-17 on `feat/servo-tuning-and-test-fix`.

## Branch state

- Branch: `feat/test-harness-ruby-box-isolation`
- HEAD: [commit SHA from `git log -1 --oneline`]
- Working tree: clean
- Commits ahead of main: [N commits]

## Per-suite outcome

| suite | isolated status | test count (legacy/isolated) |
|---|---|---|
| pc/stackchan-ble-client | isolated | [N/N] |
| mrbgems/picoruby-stackchan-led | isolated | [N/N] |
| mrbgems/picoruby-py32-io-expander | isolated | [N/N] |
| mrbgems/picoruby-ili9342 | isolated | [N/N] |
| mrbgems/picoruby-stackchan-protocol | isolated | [N/N] |
| test/ (root) | isolated / legacy-only fallback | [N/N or N/-] |

## DoD checklist

- [x] DoD #1: lib/test_isolator/{runner_main,box_runner,result_aggregator}.rb implemented + tested
- [x] DoD #2: root Rakefile :test_isolated runs
- [x] DoD #3-5: per-suite isolated green (or root legacy-only fallback documented)
- [x] DoD #6: rollback procedure in commit messages
- [x] DoD #7: CLAUDE.md cross-ref
- [x] DoD #8: rollback rehearsal verified (Phase 7)

## Next session

Resume calibration plan: `git checkout feat/servo-tuning-and-test-fix` and continue Tasks 15-17 (run_align_only / run_full_calibrate / CLI wire-up). Then HITL Task 23 on real device.
```

### Task 8.3: COMMIT 8

- [ ] **Step 1: Commit handoff**

```bash
git add docs/superpowers/handoff-2026-05-21-test-harness-isolation-complete.md
git commit -m "$(cat <<'EOF'
docs(handoff): test harness Ruby::Box isolation branch complete

All [N] of 6 suites migrated to Ruby::Box per-file isolation. Legacy
`rake test` preserved across all suites. Branch ready for PR / merge.

Next session: return to feat/servo-tuning-and-test-fix and continue
calibration plan Tasks 15-17.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review

**Spec coverage check (mapping spec sections → tasks):**
- §Section 1 (動機 / 棚卸し) → context for Task 1.1 fixtures and per-suite reads (2.1, 3.1, 4.1, 5.1)
- §Section 2 (Architecture) → Tasks 1.1–1.8 (runner) + 1.7 (root Rakefile)
- §Section 3 (Migration plan order) → Phases 2-6 in suite order (薄→厚)
- §Section 4 (Rollback 3 layers) → Phase 7 (rehearsal of L2 single-suite revert); L1 / L3 not actively rehearsed but documented in spec
- §Section 5 (YAGNI) → not exceeded (no parallel exec, no CI integration, no formatting)
- §Section 6 (DoD #1-8) → Tasks 1.x (DoD 1-2), Phases 2-6 (DoD 3-5), commit messages (DoD 6), Task 1.13 (DoD 7), Phase 7 (DoD 8)
- §Section 8 (rollback procedures quick ref) → already in spec, plan rehearses L2

**Placeholder scan:**
- `[N/N]` in Task 8.2 handoff template is an explicit fill-in slot for the implementer, not an unmet requirement.
- No "TODO" / "TBD" left.

**Type / naming consistency:**
- `TestIsolator::BoxRunner.run_file` — used in Tasks 1.3, 1.5
- `TestIsolator::ResultAggregator.aggregate` / `.render` — used in Tasks 1.4, 1.5
- `TestIsolator::Main.run` — used in Tasks 1.5, 1.8
- Result hash keys (`:test_count`, `:assertion_count`, `:failure_count`, `:error_count`, `:passed`, `:file`, `:output`) — consistent across box_runner / aggregator / tests
- Output format (`[PASS]` / `[FAIL]`, `SUMMARY  files=N tests=M ...`) — consistent across renderer and box_runner_test assertions

**Risks flagged in plan:**
- Task 1.5 Step 2: smoke test failure → STOP and BLOCKED
- Task 1.6 Step 1: isolation A/B failure → STOP, Box not isolating
- Task 2.3 Step 3: count mismatch → STOP per suite
- Task 6.1: probe failure → fall back per spec out-of-scope
- Task 6.3: explicit triage Category A/B/C with concrete fixes for B

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-05-21-test-harness-ruby-box-isolation-plan.md`.

Two execution options:

1. **Subagent-Driven (recommended)** — fresh subagent per task with two-stage review (spec compliance then code quality); fast continuous iteration
2. **Inline Execution** — execute in this session via `superpowers:executing-plans`; batch with checkpoints

Which approach?
