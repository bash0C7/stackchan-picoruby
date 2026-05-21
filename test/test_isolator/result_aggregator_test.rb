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
