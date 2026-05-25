require "test-unit"

class FailingTest < Test::Unit::TestCase
  def test_will_fail
    assert_equal 1, 2
  end

  def test_will_pass
    assert_equal 1, 1
  end
end
