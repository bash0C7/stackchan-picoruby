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
