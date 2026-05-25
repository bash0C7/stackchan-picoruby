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
