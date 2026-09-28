class CliCalibrateTest < Picotest::Test
  class CalibrationDaemon
    attr_reader :calls

    def initialize(sample_error: nil, busy: false, readings: nil)
      @calls = []
      @sample_error = sample_error
      @busy = busy
      @readings = readings
    end

    def act(name, args)
      @calls << [name.to_s, args]
      return { status: :busy, out: nil, message: "robot is held" } if @busy
      case args[0]
      when "sample"
        return { status: :error, out: nil, message: @sample_error } if @sample_error
        reading = @readings ? @readings.shift : { yaw_raw: 2048, pitch_raw: 2048 }
        { status: :ok, out: reading, message: nil }
      else
        { status: :ok, out: "OK calibrate #{args[0]}", message: nil }
      end
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
    daemon = CalibrationDaemon.new
    cli = ScriptedCLI.new(daemon)
    assert_equal 0, cli.dispatch("calibrate", ["--format", "env", "--samples", "5"])
    assert_true cli.lines.include?("SERVO_YAW_ZERO=2048\nSERVO_PITCH_ZERO=2048\nYAW_RANGE_RAW=0\nPITCH_RANGE_RAW=0\n")
    assert_equal ["calibrate", ["begin"]], daemon.calls.first
    assert_equal ["calibrate", ["sample", "5"]], daemon.calls[1]
    assert_equal 6, daemon.calls.size
  end

  def test_engage_torque_ends_the_calibration
    daemon = CalibrationDaemon.new
    cli = ScriptedCLI.new(daemon)
    assert_equal 0, cli.dispatch("calibrate", ["--engage-torque"])
    assert_equal ["calibrate", ["end"]], daemon.calls.last
  end

  def test_no_torque_toggle_only_samples
    daemon = CalibrationDaemon.new
    cli = ScriptedCLI.new(daemon)
    assert_equal 0, cli.dispatch("calibrate", ["--no-torque-toggle", "--engage-torque"])
    s = ["sample", "3"]
    assert_equal [s, s, s, s, s], daemon.calls.map { |c| c[1] }
  end

  def test_align_only_turns_torque_off_then_on
    daemon = CalibrationDaemon.new
    cli = ScriptedCLI.new(daemon)
    assert_equal 0, cli.dispatch("calibrate", ["--align-only"])
    assert_equal [["calibrate", ["begin"]], ["calibrate", ["end"]]], daemon.calls
    assert_equal 1, cli.prompts.size
  end

  def test_an_unknown_device_position_exits_6
    cli = ScriptedCLI.new(CalibrationDaemon.new(sample_error: "device returned unknown raw position"))
    assert_equal 6, cli.dispatch("calibrate", [])
    assert_equal ["[FAIL] device returned unknown raw position (manual calibration needed)"],
                 cli.lines.select { |l| l.start_with?("[FAIL]") }
  end

  def test_a_link_failure_during_sampling_is_not_reported_as_calibration_needed
    cli = ScriptedCLI.new(CalibrationDaemon.new(sample_error: "no StackChan advertiser found"))
    assert_equal 1, cli.dispatch("calibrate", [])
    assert_equal ["[FAIL] no StackChan advertiser found"], cli.lines.select { |l| l.start_with?("[FAIL]") }
  end

  def test_a_verify_delta_past_the_fail_tolerance_exits_7
    fwd = { yaw_raw: 2048, pitch_raw: 2048 }
    readings = [fwd, { yaw_raw: 1000, pitch_raw: 2048 }, { yaw_raw: 3000, pitch_raw: 2048 },
                { yaw_raw: 2048, pitch_raw: 1000 }, { yaw_raw: 2100, pitch_raw: 2048 }]
    cli = ScriptedCLI.new(CalibrationDaemon.new(readings: readings))
    assert_equal 7, cli.dispatch("calibrate", [])
  end

  def test_a_busy_robot_exits_8_before_the_first_prompt
    cli = ScriptedCLI.new(CalibrationDaemon.new(busy: true))
    assert_equal 8, cli.dispatch("calibrate", [])
    assert_equal [], cli.prompts
    assert_equal ["busy: robot is held"], cli.lines.select { |l| l.start_with?("busy:") }
  end
end
