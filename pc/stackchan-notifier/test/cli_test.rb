require_relative "helper"
require "stringio"
require "stackchan_notifier/cli"

class CLITest < Test::Unit::TestCase
  def setup
    @stdout = StringIO.new
    @stderr = StringIO.new
    @sent   = []
    @sender = ->(socket, tuple) { @sent << [socket, tuple] }
  end

  def run_cli(argv, sender: @sender)
    StackchanNotifier::CLI.run(argv, stdout: @stdout, stderr: @stderr, sender: sender)
  end

  def test_left_led_with_preset_color_produces_correct_tuple
    code = run_cli(%w[--face smile --left_led red,blink])
    assert_equal 0, code
    assert_equal 1, @sent.size
    _, tuple = @sent.first
    assert_equal :cmd,    tuple[0]
    assert_equal :notify, tuple[1]
    params = tuple[2]
    assert_equal :smile,               params[:face]
    assert_equal [0x00FFFF, :blink],   params[:left]
    assert_equal [0x000000, :solid],   params[:right]
    assert_nil                         params[:duration]
    assert_equal false,                params[:silent]
  end

  def test_both_leds_with_mixed_preset_and_hex
    code = run_cli(%w[--face smile --left_led 0xFF8800,solid --right_led green,breathing])
    assert_equal 0, code
    _, tuple = @sent.first
    assert_equal :cmd,    tuple[0]
    assert_equal :notify, tuple[1]
    params = tuple[2]
    assert_equal :smile,                 params[:face]
    assert_equal [0xFF8800, :solid],     params[:left]
    assert_equal [0x55FFFF, :breathing], params[:right]
    assert_nil                           params[:duration]
    assert_equal false,                  params[:silent]
  end

  def test_duration_appended_to_tuple
    code = run_cli(%w[--face smile --left_led red,blink --duration 5])
    assert_equal 0, code
    _, tuple = @sent.first
    assert_equal :cmd,    tuple[0]
    assert_equal :notify, tuple[1]
    params = tuple[2]
    assert_equal :smile,             params[:face]
    assert_equal [0x00FFFF, :blink], params[:left]
    assert_equal [0x000000, :solid], params[:right]
    assert_equal 5,                  params[:duration]
    assert_equal false,              params[:silent]
  end

  def test_duration_zero_exits_2_with_stderr_message
    code = run_cli(%w[--face smile --duration 0])
    assert_equal 2, code
    assert_match(/must be a positive integer/, @stderr.string)
  end

  def test_left_led_missing_mode_exits_2
    code = run_cli(%w[--face smile --left_led red])
    assert_equal 2, code
    assert_match(/must be COLOR,MODE/, @stderr.string)
  end

  def test_left_led_unknown_preset_exits_2
    code = run_cli(%w[--face smile --left_led purple,solid])
    assert_equal 2, code
    assert_match(/must be a preset name/, @stderr.string)
  end

  def test_left_led_hex_too_long_exits_2
    code = run_cli(%w[--face smile --left_led 0xFFFFFFF,solid])
    assert_equal 2, code
    assert_match(/out of range/, @stderr.string)
  end

  def test_left_led_invalid_mode_exits_2
    code = run_cli(%w[--face smile --left_led red,wobble])
    assert_equal 2, code
    assert_match(/mode must be one of/, @stderr.string)
  end

  def test_missing_face_exits_2_with_stderr_message
    code = run_cli(%w[--left_led red,blink])
    assert_equal 2, code
    assert_match(/--face required/, @stderr.string)
  end

  def test_face_sad_accepted
    code = run_cli(%w[--face sad --left_led red,solid])
    assert_equal 0, code, @stderr.string
    _, tuple = @sent.first
    assert_equal :sad, tuple[2][:face]
  end

  def test_face_angry_accepted
    code = run_cli(%w[--face angry --left_led red,solid])
    assert_equal 0, code, @stderr.string
    _, tuple = @sent.first
    assert_equal :angry, tuple[2][:face]
  end

  def test_face_unknown_rejected_lists_sad_and_angry
    code = run_cli(%w[--face confused --left_led red,solid])
    assert_equal 2, code
    assert_match(/sad/, @stderr.string)
    assert_match(/angry/, @stderr.string)
  end

  def test_quiet_suppresses_daemon_unavailable_stderr
    failing = ->(_s, _t) { raise DRb::DRbConnError, "connection refused" }
    code = run_cli(%w[--face smile --quiet], sender: failing)
    assert_equal 0, code
    assert_equal "", @stderr.string
  end

  def test_daemon_unavailable_without_quiet_warns_stderr_exits_0
    failing = ->(_s, _t) { raise DRb::DRbConnError, "connection refused" }
    code = run_cli(%w[--face smile], sender: failing)
    assert_equal 0, code, "must not block Claude Code on daemon failure"
    assert_match(/daemon unavailable/, @stderr.string)
  end

  def test_socket_env_honored
    ENV["STACKCHAN_NOTIFIER_SOCKET"] = "/tmp/env-overridden.sock"
    run_cli(%w[--face smile])
    socket, _ = @sent.first
    assert_equal "/tmp/env-overridden.sock", socket
  ensure
    ENV.delete("STACKCHAN_NOTIFIER_SOCKET")
  end

  def test_socket_flag_overrides_env
    ENV["STACKCHAN_NOTIFIER_SOCKET"] = "/tmp/env-overridden.sock"
    run_cli(%w[--face smile --socket /tmp/custom.sock])
    socket, _ = @sent.first
    assert_equal "/tmp/custom.sock", socket
  ensure
    ENV.delete("STACKCHAN_NOTIFIER_SOCKET")
  end

  def test_silent_flag_sets_silent_true_in_tuple
    sent = []
    sender = ->(_socket, tuple) { sent << tuple }
    StackchanNotifier::CLI.run(
      %w[--face joy --silent],
      stdout: StringIO.new, stderr: StringIO.new, sender: sender,
    )
    assert_equal true, sent[0][2][:silent]
  end

  def test_default_silent_is_false
    sent = []
    sender = ->(_socket, tuple) { sent << tuple }
    StackchanNotifier::CLI.run(
      %w[--face joy],
      stdout: StringIO.new, stderr: StringIO.new, sender: sender,
    )
    assert_equal false, sent[0][2][:silent]
  end
end
