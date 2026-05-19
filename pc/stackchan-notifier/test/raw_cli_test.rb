require "helper"
require "stackchan_notifier/raw_cli"

class RawCLITest < Test::Unit::TestCase
  def test_frame_writes_expected_tuple
    sent = []
    sender = ->(_s, t) { sent << t }
    rc = StackchanNotifier::RawCLI.run(
      ["--frame", "<F:2>"],
      stdout: StringIO.new, stderr: StringIO.new, sender: sender,
    )
    assert_equal 0, rc
    assert_equal [:cmd, :raw, { frame: "<F:2>" }], sent[0]
  end

  def test_missing_frame_exits_bad_arg
    stderr = StringIO.new
    rc = StackchanNotifier::RawCLI.run(
      [], stdout: StringIO.new, stderr: stderr, sender: ->(*) {},
    )
    assert_equal 2, rc
    assert_match(/--frame/, stderr.string)
  end

  def test_empty_frame_exits_bad_arg
    stderr = StringIO.new
    rc = StackchanNotifier::RawCLI.run(
      ["--frame", ""], stdout: StringIO.new, stderr: stderr, sender: ->(*) {},
    )
    assert_equal 2, rc
    assert_match(/frame must not be empty/, stderr.string)
  end
end
