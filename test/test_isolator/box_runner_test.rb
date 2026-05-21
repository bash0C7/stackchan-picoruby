require "test-unit"
require "open3"

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
