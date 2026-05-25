require "test-unit"

class PassingTest < Test::Unit::TestCase
  def test_one_plus_one
    assert_equal 2, 1 + 1
  end

  def test_string_concat
    assert_equal "ab", "a" + "b"
  end
end
