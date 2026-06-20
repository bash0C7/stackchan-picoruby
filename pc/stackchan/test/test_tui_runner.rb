require_relative "test_helper"
require "stringio"
require "stackchan/tui"

class TestTUIRunner < Test::Unit::TestCase
  class FakeDaemon
    attr_reader :calls
    def initialize; @calls = []; end
    def servo(**kw); @calls << [:servo, kw]; nil; end
    def torque(on); @calls << [:torque, on]; end
    def face(name); @calls << [:face, name]; end
  end

  def run_with_script(script)
    daemon = FakeDaemon.new
    stdin = StringIO.new(script)
    stdout = StringIO.new
    Stackchan::TUI::Runner.new(daemon, stdin: stdin, stdout: stdout).run
    [daemon.calls, stdout.string]
  end

  def test_yl_dispatches_servo_with_yaw_left
    calls, _ = run_with_script("yl 50\nq\n")
    assert_equal [:servo, { yaw_left: 50, time_ms: 800 }], calls.first
  end

  def test_fwd_zeroes_yaw_and_pitch
    calls, _ = run_with_script("fwd\nq\n")
    assert_equal [:servo, { yaw_left: 0, pitch_up: 0, time_ms: 800 }], calls.first
  end

  def test_t_changes_move_ms_for_subsequent_moves
    calls, _ = run_with_script("t 200\nyl 30\nq\n")
    assert_equal [:servo, { yaw_left: 30, time_ms: 200 }], calls.first
  end

  def test_ton_toff_calls_torque
    calls, _ = run_with_script("ton\ntoff\nq\n")
    assert_equal [[:torque, true], [:torque, false]], calls
  end

  def test_face_requires_argument
    _, out = run_with_script("face\nq\n")
    assert out.include?("error: face requires a name")
  end

  def test_magnitude_out_of_range_reports_error
    _, out = run_with_script("yl 200\nq\n")
    assert out.include?("error:")
  end

  def test_unknown_command_reports
    _, out = run_with_script("zzz\nq\n")
    assert out.include?("unknown: zzz")
  end
end
