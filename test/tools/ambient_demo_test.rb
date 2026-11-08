class AmbientDemoTest < Picotest::Test
  class FakeCli
    attr_reader :calls

    def initialize(codes)
      @codes = codes
      @calls = []
    end

    def run(*args)
      @calls << args
      @codes.shift || 0
    end
  end

  def wait(codes)
    @cli = FakeCli.new(codes)
    @sleeps = []
    AmbientDemo.wait_until_connected(@cli, ->(s) { @sleeps << s })
  end

  def test_connect_is_retried_after_3_s_while_the_robot_is_busy
    assert_equal true, wait([8, 8, 0])
    assert_equal [["connect"]] * 3, @cli.calls
    assert_equal [3, 3], @sleeps
  end

  def test_any_other_failure_gives_up_at_once
    assert_equal false, wait([1, 0])
    assert_equal [["connect"]], @cli.calls
    assert_equal [], @sleeps
  end

  def test_rest_turns_the_leds_off_faces_neutral_centres_and_releases_torque
    cli = FakeCli.new([])
    AmbientDemo.rest_state(cli)
    assert_equal [%w[led both off off], %w[face neutral],
                  ["servo", "--yaw-left", 0, "--pitch-up", 0, "--time", 800], %w[torque off]], cli.calls
  end

  def test_the_cli_reports_the_exit_code_of_the_command
    assert_equal 0, AmbientDemo::Cli.new("true").run("connect")
    assert_equal 1, AmbientDemo::Cli.new("false").run("connect")
  end
end
