class CliCalibrateTest < Picotest::Test
  class CalibrationDaemon
    attr_reader :calls

    def initialize(sample_error: nil)
      @calls = []
      @sample_error = sample_error
    end

    def torque(on)
      @calls << [:torque, on]
      "OK torque"
    end

    def sample_pose(n)
      @calls << [:sample_pose, n]
      raise @sample_error if @sample_error
      { yaw_raw: 2048, pitch_raw: 2048 }
    end
  end

  class ScriptedCLI < StackChan::Controller::CLI
    attr_reader :lines, :prompts

    def initialize(daemon)
      super(daemon)
      @lines = []
      @prompts = []
    end

    private

    def out(s)
      @lines << s
    end

    def prompt_enter(msg)
      @prompts << msg
    end
  end

  def test_an_unknown_format_is_rejected_before_the_first_prompt
    daemon = CalibrationDaemon.new
    cli = ScriptedCLI.new(daemon)
    assert_equal 1, cli.dispatch("calibrate", ["--format", "yaml"])
    assert_equal [], cli.prompts
    assert_equal [], daemon.calls
  end

  def test_a_known_format_prints_the_anchors
    cli = ScriptedCLI.new(CalibrationDaemon.new)
    assert_equal 0, cli.dispatch("calibrate", ["--format", "env"])
    assert_true cli.lines.include?("SERVO_YAW_ZERO=2048\nSERVO_PITCH_ZERO=2048\nYAW_RANGE_RAW=0\nPITCH_RANGE_RAW=0\n")
  end

  def test_an_unknown_device_position_exits_6
    error = RuntimeError.new("StackChan::Controller::DeviceError: device returned unknown raw position")
    cli = ScriptedCLI.new(CalibrationDaemon.new(sample_error: error))
    assert_equal 6, cli.dispatch("calibrate", [])
  end

  def test_a_link_failure_during_sampling_is_not_reported_as_calibration_needed
    error = RuntimeError.new("StackChan::Controller::ConnectionError: no StackChan advertiser found")
    cli = ScriptedCLI.new(CalibrationDaemon.new(sample_error: error))
    assert_equal 1, cli.dispatch("calibrate", [])
    assert_equal ["[FAIL] StackChan::Controller::ConnectionError: no StackChan advertiser found"], cli.lines.select { |l| l.start_with?("[FAIL]") }
  end
end
