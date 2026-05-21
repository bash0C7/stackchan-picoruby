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
