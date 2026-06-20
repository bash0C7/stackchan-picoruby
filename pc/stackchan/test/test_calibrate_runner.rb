require_relative "test_helper"
require "stringio"
require "stackchan/calibrate"

class TestCalibrateAlignOnly < Test::Unit::TestCase
  class FakeDaemon
    attr_reader :torque_calls
    def initialize; @torque_calls = []; end
    def torque(on); @torque_calls << on; end
  end

  def test_align_only_toggles_torque_around_prompt
    daemon = FakeDaemon.new
    stdin = StringIO.new("\n")
    stdout = StringIO.new
    rc = Stackchan::Calibrate::Runner.new(daemon, stdin: stdin, stdout: stdout)
      .run(align_only: true)
    assert_equal Stackchan::Calibrate::EXIT_OK, rc
    assert_equal [false, true], daemon.torque_calls
    assert stdout.string.include?("[done] Ready for operation.")
  end

  def test_align_only_with_no_torque_toggle_skips_torque
    daemon = FakeDaemon.new
    rc = Stackchan::Calibrate::Runner.new(daemon, stdin: StringIO.new("\n"), stdout: StringIO.new)
      .run(align_only: true, no_torque_toggle: true)
    assert_equal Stackchan::Calibrate::EXIT_OK, rc
    assert_equal [], daemon.torque_calls
  end
end

class TestCalibrateFull < Test::Unit::TestCase
  class FakeDaemon
    POSES = {
      forward:    { yaw_raw: 1000, pitch_raw: 1200 },
      left_max:   { yaw_raw: 1300, pitch_raw: 1200 },
      right_max:  { yaw_raw:  700, pitch_raw: 1200 },
      up_max:     { yaw_raw: 1000, pitch_raw: 1500 },
      fwd_verify: { yaw_raw: 1001, pitch_raw: 1201 }, # within PASS tolerance
    }.freeze

    def initialize; @pose_idx = 0; @torques = []; end
    def torque(on); @torques << on; end
    def sample_pose(samples:)
      keys = POSES.keys
      key = keys[@pose_idx]
      @pose_idx += 1
      POSES[key]
    end
  end

  def test_full_calibrate_pass_outcome_prints_ruby_format
    daemon = FakeDaemon.new
    stdin = StringIO.new("\n" * 5)
    stdout = StringIO.new
    rc = Stackchan::Calibrate::Runner.new(daemon, stdin: stdin, stdout: stdout)
      .run(align_only: false, samples: 1, format: :ruby)
    assert_equal Stackchan::Calibrate::EXIT_OK, rc
    assert stdout.string.include?("SERVO_YAW_ZERO   = 1000")
    assert stdout.string.include?("YAW_RANGE_RAW    = 300")
  end
end
