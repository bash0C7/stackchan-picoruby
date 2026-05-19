require "helper"
require "stackchan_notifier/servo_cli"

class ServoCLITest < Test::Unit::TestCase
  def test_yaw_pitch_time_writes_expected_tuple
    sent = []
    sender = ->(_s, t) { sent << t }
    rc = StackchanNotifier::ServoCLI.run(
      %w[--yaw -300 --pitch 500 --time 2000],
      stdout: StringIO.new, stderr: StringIO.new, sender: sender,
    )
    assert_equal 0, rc
    assert_equal :cmd,   sent[0][0]
    assert_equal :servo, sent[0][1]
    assert_equal({ yaw: -300, pitch: 500, time_ms: 2000, velocity: nil }, sent[0][2])
  end

  def test_yaw_only_with_velocity
    sent = []
    sender = ->(_s, t) { sent << t }
    StackchanNotifier::ServoCLI.run(
      %w[--yaw 100 --velocity 50],
      stdout: StringIO.new, stderr: StringIO.new, sender: sender,
    )
    assert_equal({ yaw: 100, pitch: nil, time_ms: nil, velocity: 50 }, sent[0][2])
  end

  def test_missing_both_yaw_and_pitch_exits_bad_arg
    stderr = StringIO.new
    sent = []
    sender = ->(_s, t) { sent << t }
    rc = StackchanNotifier::ServoCLI.run(
      %w[--time 1000],
      stdout: StringIO.new, stderr: stderr, sender: sender,
    )
    assert_equal 2, rc
    assert_match(/yaw or --pitch/, stderr.string)
    assert_empty sent
  end

  def test_invalid_integer_exits_bad_arg
    stderr = StringIO.new
    rc = StackchanNotifier::ServoCLI.run(
      %w[--yaw foo],
      stdout: StringIO.new, stderr: stderr, sender: ->(*) {},
    )
    assert_equal 2, rc
  end
end
