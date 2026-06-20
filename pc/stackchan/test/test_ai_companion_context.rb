require_relative "test_helper"
require "stackchan/ai"

class TestAICompanionContext < Test::Unit::TestCase
  # Reach into the private build_situation helper to assert context shaping
  # without needing a live AppleFoundationModel session.
  def setup
    # Don't go through .new — that creates a real FM Session. We just need
    # the build_situation behaviour, so allocate without initialize.
    @companion = Stackchan::AI::Companion.allocate
  end

  def call_build(context)
    @companion.send(:build_situation, context)
  end

  def test_empty_context_returns_empty_string
    assert_equal "", call_build(nil)
    assert_equal "", call_build({})
  end

  def test_face_and_say_included
    out = call_build(last_face: "joy", last_say: "やあ")
    assert out.include?("今の表情: joy")
    assert out.include?("自分が直前に言ったこと: 「やあ」")
  end

  def test_last_heard_included
    out = call_build(last_heard: "頭頂部を触られた")
    assert out.include?("直前に相手から聞いた話: 「頭頂部を触られた」")
  end

  def test_touch_zone_label_preferred_over_raw_zone
    out = call_build(touch_zone: 1, touch_zone_label: "左こめかみ")
    assert out.include?("今、左こめかみを触られた")
    assert_false out.include?("zone=1")
  end

  def test_touch_zone_raw_when_no_label
    out = call_build(touch_zone: 9)
    assert out.include?("zone=9")
  end

  def test_action_elapsed_seconds
    out = call_build(last_action: "demo", last_action_at: Time.now - 5)
    assert out =~ /\d+秒前に「demo」をした/
  end
end
