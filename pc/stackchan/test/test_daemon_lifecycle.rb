require_relative "test_helper"
require "stackchan/daemon"

class TestDaemonLifecycle < Test::Unit::TestCase
  def test_default_socket_path_is_uid_based
    daemon = Stackchan::Daemon.new(socket_path: "/tmp/stackchan-test-#{Process.uid}.sock")
    assert_equal "/tmp/stackchan-test-#{Process.uid}.sock", daemon.socket_path
  end

  def test_status_before_start_reports_no_connection
    daemon = Stackchan::Daemon.new(socket_path: "/tmp/stackchan-test-#{Process.uid}.sock")
    s = daemon.status
    assert_false s[:ble_connected]
    assert_false s[:ai_session]
    assert_equal "/tmp/stackchan-test-#{Process.uid}.sock", s[:socket]
  end

  def test_stop_releases_wait
    daemon = Stackchan::Daemon.new(socket_path: "/tmp/stackchan-test-#{Process.uid}.sock")
    waiter = Thread.new { daemon.wait }
    sleep 0.05
    assert_true waiter.alive?
    daemon.stop
    waiter.join(1)
    assert_false waiter.alive?
  end
end
