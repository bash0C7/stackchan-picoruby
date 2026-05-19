require "helper"
require "stackchan_notifier/cli_base"

class CliBaseTest < Test::Unit::TestCase
  def test_try_send_calls_sender_with_socket_and_tuple
    sent = nil
    sender = ->(socket, tuple) { sent = [socket, tuple] }
    stderr = StringIO.new
    StackchanNotifier::CliBase.try_send(
      sender: sender,
      socket: "/tmp/xx.sock",
      tuple:  [:cmd, :notify, { face: :joy }],
      stderr: stderr,
      quiet:  false,
      program_name: "stackchan-notify",
    )
    assert_equal ["/tmp/xx.sock", [:cmd, :notify, { face: :joy }]], sent
    assert_equal "", stderr.string
  end

  def test_try_send_swallows_daemon_unavailable_and_warns
    sender = ->(_s, _t) { raise Errno::ENOENT, "No such file" }
    stderr = StringIO.new
    StackchanNotifier::CliBase.try_send(
      sender: sender,
      socket: "/tmp/missing.sock",
      tuple:  [:cmd, :notify, {}],
      stderr: stderr,
      quiet:  false,
      program_name: "stackchan-notify",
    )
    assert_match(/stackchan-notify: daemon unavailable/, stderr.string)
    assert_match(/Errno::ENOENT/, stderr.string)
  end

  def test_try_send_quiet_suppresses_warn
    sender = ->(_s, _t) { raise Errno::ENOENT, "No such file" }
    stderr = StringIO.new
    StackchanNotifier::CliBase.try_send(
      sender: sender, socket: "/tmp/x.sock", tuple: [:cmd, :raw, {}],
      stderr: stderr, quiet: true, program_name: "stackchan-raw",
    )
    assert_equal "", stderr.string
  end

  def test_try_send_swallows_drb_conn_error
    sender = ->(_s, _t) { raise DRb::DRbConnError, "boom" }
    stderr = StringIO.new
    StackchanNotifier::CliBase.try_send(
      sender: sender, socket: "/tmp/x.sock", tuple: [:cmd, :raw, {}],
      stderr: stderr, quiet: false, program_name: "stackchan-raw",
    )
    assert_match(/DRb::DRbConnError/, stderr.string)
  end
end
