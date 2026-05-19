require "helper"
require "stackchan_notifier/notify_motion_table"

class NotifyMotionTableTest < Test::Unit::TestCase
  def test_lookup_neutral
    assert_equal({ yaw: 0, pitch: 450, time_ms: 300 },
                 StackchanNotifier::NotifyMotionTable.lookup(:neutral))
  end

  def test_lookup_joy
    assert_equal({ yaw: 0, pitch: 600, time_ms: 250 },
                 StackchanNotifier::NotifyMotionTable.lookup(:joy))
  end

  def test_lookup_smile
    assert_equal({ yaw: 0, pitch: 500, time_ms: 300 },
                 StackchanNotifier::NotifyMotionTable.lookup(:smile))
  end

  def test_lookup_surprised
    assert_equal({ yaw: 0, pitch: 750, time_ms: 120 },
                 StackchanNotifier::NotifyMotionTable.lookup(:surprised))
  end

  def test_lookup_sad
    assert_equal({ yaw: 0, pitch: 280, time_ms: 500 },
                 StackchanNotifier::NotifyMotionTable.lookup(:sad))
  end

  def test_lookup_angry
    assert_equal({ yaw: 150, pitch: 450, time_ms: 200 },
                 StackchanNotifier::NotifyMotionTable.lookup(:angry))
  end

  def test_lookup_unknown_face_returns_nil
    assert_nil StackchanNotifier::NotifyMotionTable.lookup(:bogus)
  end

  def test_motions_is_frozen
    assert_predicate StackchanNotifier::NotifyMotionTable::MOTIONS, :frozen?
  end
end
