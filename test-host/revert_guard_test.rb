require "test/unit"
require "tmpdir"
require "fileutils"
require "open3"
require "stringio"
require "revert_guard"

class RevertGuardTest < Test::Unit::TestCase
  CALC = <<~RUBY
    module Calc
      def self.add(a, b) = a + b
    end
  RUBY

  CALC_WITH_SUB = <<~RUBY
    module Calc
      def self.add(a, b) = a + b
      def self.sub(a, b) = a - b
    end
  RUBY

  CALC_TEST = <<~RUBY
    require "test/unit"
    require_relative "../lib/calc"

    class CalcTest < Test::Unit::TestCase
      def #{"test_add"}
        assert_equal 2, Calc.add(1, 1)
      end
    end
  RUBY

  def git(dir, *args)
    out, status = Open3.capture2e("git", "-C", dir, *args)
    raise "git #{args.join(' ')} failed:\n#{out}" unless status.success?
    out
  end

  def commit(dir, message)
    git(dir, "add", "-A")
    git(dir, "-c", "user.email=test@example.com", "-c", "user.name=Test",
        "-c", "commit.gpgsign=false", "commit", "-q", "-m", message)
    git(dir, "rev-parse", "HEAD").strip
  end

  def write(dir, path, content)
    full = File.join(dir, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, content)
  end

  def run_guard(dir, base)
    err = StringIO.new
    code = RevertGuard.new(root: dir, base: base, err: err).run
    [err.string, code]
  end

  def test_a_new_test_that_fails_on_the_base_passes_the_guard
    Dir.mktmpdir do |dir|
      git(dir, "init", "-q")
      write(dir, "lib/calc.rb", CALC)
      write(dir, "test-host/calc_test.rb", CALC_TEST)
      base = commit(dir, "base")

      write(dir, "lib/calc.rb", CALC_WITH_SUB)
      write(dir, "test-host/calc_test.rb", CALC_TEST.sub(
        "end\nend\n", "end\n\n  def #{"test_sub"}\n    assert_equal 2, Calc.sub(3, 1)\n  end\nend\n"))
      commit(dir, "add sub")

      err, code = run_guard(dir, base)
      assert_equal 0, code, err
    end
  end

  def test_a_new_test_that_still_passes_on_the_base_is_rejected
    Dir.mktmpdir do |dir|
      git(dir, "init", "-q")
      write(dir, "lib/calc.rb", CALC)
      write(dir, "test-host/calc_test.rb", CALC_TEST)
      base = commit(dir, "base")

      write(dir, "lib/calc.rb", CALC_WITH_SUB)
      write(dir, "test-host/calc_test.rb", CALC_TEST.sub(
        "end\nend\n", "end\n\n  def #{"test_add_again"}\n    assert_equal 2, Calc.add(1, 1)\n  end\nend\n"))
      commit(dir, "add redundant test")

      err, code = run_guard(dir, base)
      assert_equal 1, code, err
      assert_match(/pass with the code reverted/, err)
    end
  end

  def test_a_picotest_file_that_crashes_while_loading_on_the_base_counts_as_unloadable
    out = "[31mAmbientDemoTest:\n  success: 0, failure: 0, exception: 0, crash: 1, skip: 0\n" \
          "[0m[31mCrash in loading: /tmp/base/test/tools/ambient_demo_test.rb: RuntimeError: Crash in running AmbientDemoTest tests.\n"
    assert_true RevertGuard.unloadable?("test/tools/ambient_demo_test.rb", out)
    assert_false RevertGuard.unloadable?("test/tools/ambient_demo_test.rb", "  AmbientDemoTest#test_x F\n")
    assert_false RevertGuard.unloadable?("test-host/foo_test.rb", out)
  end

  def test_a_test_host_file_that_cannot_load_on_the_base_is_skipped
    Dir.mktmpdir do |dir|
      git(dir, "init", "-q")
      write(dir, "lib/calc.rb", CALC)
      base = commit(dir, "base")

      write(dir, "lib/foo.rb", "module Foo\n  def self.answer = 42\nend\n")
      write(dir, "test-host/foo_test.rb", <<~RUBY)
        require "test/unit"
        require_relative "../lib/foo"

        class FooTest < Test::Unit::TestCase
          def #{"test_foo"}
            assert_equal 42, Foo.answer
          end
        end
      RUBY
      commit(dir, "add foo")

      err, code = run_guard(dir, base)
      assert_equal 0, code, err
    end
  end
end
