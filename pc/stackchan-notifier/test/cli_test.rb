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

  def test_success_writes_one_tuple_with_parsed_values
    code = run_cli(%w[--face smile --hsb 0x00FF00 --mode solid --side both])
    assert_equal 0, code
    assert_equal 1, @sent.size
    socket, tuple = @sent.first
    assert_equal StackchanNotifier.default_socket_path, socket
    assert_equal [:notify, :smile, 0x00FF00, :solid, :both], tuple
  end

  def test_default_side_is_both
    run_cli(%w[--face joy --hsb 0xABCDEF --mode blink])
    _, tuple = @sent.first
    assert_equal :both, tuple[4]
  end

  def test_hsb_accepts_bare_hex_without_prefix
    run_cli(%w[--face neutral --hsb 55FF80 --mode off])
    _, tuple = @sent.first
    assert_equal 0x55FF80, tuple[2]
  end

  def test_socket_can_be_overridden_via_flag
    run_cli(%w[--face smile --hsb 0x111111 --mode solid --socket /tmp/custom.sock])
    socket, _ = @sent.first
    assert_equal "/tmp/custom.sock", socket
  end

  def test_socket_can_be_overridden_via_env
    ENV["STACKCHAN_NOTIFIER_SOCKET"] = "/tmp/env-overridden.sock"
    run_cli(%w[--face smile --hsb 0x111111 --mode solid])
    socket, _ = @sent.first
    assert_equal "/tmp/env-overridden.sock", socket
  ensure
    ENV.delete("STACKCHAN_NOTIFIER_SOCKET")
  end

  def test_missing_face_exits_2_with_stderr_message
    code = run_cli(%w[--hsb 0x00FF00 --mode solid])
    assert_equal 2, code
    assert_match(/--face required/, @stderr.string)
  end

  def test_invalid_face_value_exits_2
    code = run_cli(%w[--face angry --hsb 0x00FF00 --mode solid])
    assert_equal 2, code
    assert_match(/--face required/, @stderr.string)
  end

  def test_invalid_mode_exits_2
    code = run_cli(%w[--face smile --hsb 0x00FF00 --mode strobe])
    assert_equal 2, code
    assert_match(/--mode required/, @stderr.string)
  end

  def test_invalid_hsb_exits_2
    code = run_cli(%w[--face smile --hsb not-hex --mode solid])
    assert_equal 2, code
    assert_match(/--hsb must be a hex/, @stderr.string)
  end

  def test_hsb_out_of_range_exits_2
    code = run_cli(%w[--face smile --hsb 0x1000000 --mode solid])
    assert_equal 2, code
    assert_match(/--hsb out of range/, @stderr.string)
  end

  def test_invalid_side_exits_2
    code = run_cli(%w[--face smile --hsb 0x00FF00 --mode solid --side back])
    assert_equal 2, code
    assert_match(/--side/, @stderr.string)
  end

  def test_daemon_unavailable_with_quiet_exits_0_silently
    failing = ->(_s, _t) { raise DRb::DRbConnError, "connection refused" }
    code = run_cli(%w[--face smile --hsb 0x00FF00 --mode solid --quiet], sender: failing)
    assert_equal 0, code
    assert_equal "", @stderr.string
  end

  def test_daemon_unavailable_without_quiet_warns_on_stderr_but_still_exits_0
    failing = ->(_s, _t) { raise DRb::DRbConnError, "connection refused" }
    code = run_cli(%w[--face smile --hsb 0x00FF00 --mode solid], sender: failing)
    assert_equal 0, code, "must not block Claude Code on daemon failure"
    assert_match(/daemon unavailable/, @stderr.string)
  end

  def test_enoent_socket_treated_as_daemon_unavailable
    failing = ->(_s, _t) { raise Errno::ENOENT, "/tmp/missing.sock" }
    code = run_cli(%w[--face smile --hsb 0x00FF00 --mode solid --quiet], sender: failing)
    assert_equal 0, code
  end
end
