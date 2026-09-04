# `stackchan stop` reported DRb::DRbConnError and exit 1 while the daemon had
# in fact stopped. Daemon#stop runs inside the drb accept Task that still owes
# the caller a reply, so tearing the service down inline killed the writer
# before it wrote. The teardown must still be pending when stop returns.
class DaemonStopTest < Picotest::Test
  def setup
    DRb.reset_stop_service_calls
    @ble = FakeStoppableBle.new
    @daemon = Stackchan::Daemon.new(ble: @ble)
  end

  def test_stop_answers_the_caller
    assert_true @daemon.stop
  end

  def test_stop_leaves_the_drb_service_up_so_the_reply_can_be_written
    @daemon.stop
    assert_equal 0, DRb.stop_service_calls
  end

  def test_stop_leaves_the_ble_link_up_until_the_reply_is_out
    @daemon.stop
    assert_equal 0, @ble.disconnect_calls
  end
end
