class CentralLinkLossTest < Picotest::Test
  RX  = FakeRobotRadio::RX
  TX  = FakeRobotRadio::TX
  DRX = FakeRobotRadio::DRX
  DTX = FakeRobotRadio::DTX

  class DropOnWriteRadio < FakeRobotRadio
    def answer(frame)
      drop_link(event: true)
    end
  end

  def build_central(radio)
    StackChan::Controller::Central.new(
      name_prefix: "StackChan",
      radio: radio,
      log_fn: ->(line) { @logs << line },
    )
  end

  def setup
    FakeClock.reset(1000)
    @logs = []
    @radio = FakeRobotRadio.new
    @central = build_central(@radio)
    @central.connect
    FakeClock.sleeps.clear
    @logs.clear
  end

  def sleep_total
    total = 0
    FakeClock.sleeps.each { |ms| total += ms }
    total
  end

  def test_a_drained_disconnect_packet_marks_the_link_lost
    @radio.drop_link(event: true)
    @central.drain
    assert_false @central.connected?
    assert_true @central.lost?
  end

  def test_connect_clears_the_loss
    @radio.drop_link(event: true)
    @central.drain
    @central.connect
    assert_true @central.connected?
    assert_false @central.lost?
  end

  class DropOnSubscribeRadio < FakeRobotRadio
    def write_characteristic_descriptor_using_descriptor_handle(conn_handle, handle, value)
      super
      drop_link(event: true)
    end
  end

  def test_a_drop_while_subscribing_fails_the_connect
    central = build_central(DropOnSubscribeRadio.new)
    assert_raise(StackChan::Controller::ConnectionError) { central.connect }
    assert_false central.connected?
  end

  def test_remote_after_an_undrained_drop_raises_connection_error
    @radio.drop_link(event: true)
    assert_raise(StackChan::Controller::ConnectionError) { @central.remote }
    assert_equal [], @radio.writes_after_drop
  end

  def test_send_chunk_after_a_drained_drop_raises_connection_error
    @radio.drop_link(event: true)
    @central.drain
    assert_raise(StackChan::Controller::ConnectionError) { @central.send_chunk("a") }
    assert_equal [], @radio.writes_after_drop
  end

  def test_a_disconnect_still_queued_at_connect_is_consumed_by_the_scan
    @radio.drop_link(event: true)
    @central.connect
    assert_true @central.connected?
    assert_false @central.lost?
    @central.raw_send("<F:2>\n")
    assert_equal ["<F:2>\n"], @radio.rx_frames
  end

  def test_a_drb_chunk_from_the_old_link_is_gone_after_reconnect
    @radio.schedule_notification(DTX, "stale")
    @central.drain
    @radio.drop_link(event: true)
    @central.drain
    @central.connect
    assert_nil @central.poll
  end

  def test_the_first_drb_chunk_after_a_reconnect_does_not_wait
    @central.send_chunk("a")
    sent_at = FakeClock.now
    @radio.drop_link(event: true)
    @central.drain
    @central.connect
    FakeClock.reset(sent_at)
    @central.send_chunk("b")
    assert_equal [], FakeClock.sleeps
  end

  def test_a_drop_during_the_ack_wait_raises_connection_error_at_the_next_poll
    radio = DropOnWriteRadio.new
    central = build_central(radio)
    central.connect
    FakeClock.sleeps.clear
    assert_raise(StackChan::Controller::ConnectionError) { central.raw_send("<F:2>\n") }
    assert_equal [], FakeClock.sleeps
    assert_false central.connected?
  end

  def test_a_silent_drop_costs_the_full_ack_timeout
    @radio.drop_link(event: false)
    assert_raise(StackChan::Controller::TimeoutError) { @central.raw_send("<F:2>\n") }
    assert_equal StackChan::Controller::Central::ACK_TIMEOUT_MS, sleep_total
    assert_equal [[RX, "<F:2>\n"]], @radio.writes_after_drop
  end

  def test_a_drop_during_the_audio_wait_raises_connection_error
    @radio.drop_link(event: true)
    assert_raise(StackChan::Controller::ConnectionError) { @central.await_audio_done(240) }
    assert_equal [], FakeClock.sleeps
  end

  def test_a_drop_during_a_drb_reply_wait_raises_connection_error
    front = @central.remote
    @radio.drop_link(event: true)
    assert_raise(StackChan::Controller::ConnectionError) { front.face(2) }
    assert_equal [], FakeClock.sleeps
  end

  def test_connect_against_a_silent_robot_raises_and_scans_once
    radio = FakeRobotRadio.new
    radio.advertising = false
    assert_raise(StackChan::Controller::ConnectionError) { build_central(radio).connect }
    assert_equal 1, radio.connect_and_discover_calls
  end

  def test_a_failed_connect_is_followed_by_a_good_one
    radio = FakeRobotRadio.new
    radio.fail_next_connects(1)
    central = build_central(radio)
    assert_raise(StackChan::Controller::ConnectionError) { central.connect }
    central.connect
    assert_true central.connected?
    assert_equal 2, radio.connect_and_discover_calls
  end

  def test_selftest_keeps_its_detail_and_the_next_frame_gets_its_own_ack
    @central.raw_send("<selftest:run>\n")
    assert_equal "<YL_actual:0,PU_actual:0>\n", @central.last_detail_frame
    @central.raw_send("<F:2>\n")
    assert_nil @central.last_detail_frame
    assert_equal ["<selftest:run>\n", "<F:2>\n"], @radio.rx_frames
  end

  def test_the_robot_acks_read_pos_before_the_reading
    @central.raw_send("<read:pos>\n")
    assert_equal ["[t] <read:pos> ack=0ms detail=0ms"], @logs
  end

  def test_keepalive_sends_read_pos_and_keeps_the_reading
    @central.keepalive
    assert_equal ["<read:pos>\n"], @radio.rx_frames
    assert_equal "<yaw_raw:2048,pitch_raw:2048>\n", @central.last_detail_frame
  end

  def test_the_robot_releases_after_its_quiet_time
    @radio.release_after(5000)
    @central.raw_send("<F:2>\n")
    sleep_ms 5000
    @central.drain
    assert_false @central.connected?
    @central.connect
    @central.raw_send("<F:3>\n")
    assert_equal ["<F:2>\n", "<F:3>\n"], @radio.rx_frames
  end

  def test_touch_reaches_on_unsolicited_only_while_the_link_is_up
    got = []
    @central.on_unsolicited = ->(frame) { got << frame }
    @radio.touch(1)
    @central.drain
    @radio.drop_link(event: true)
    @radio.touch(2)
    @central.drain
    assert_equal ["<touch:1>\n"], got
  end

  def test_audio_is_answered_ready_then_done_after_n_bytes
    @central.write_without_ack("<A:4>\n")
    @central.write_without_ack("ab")
    @central.write_without_ack("cd")
    @central.await_audio_done(4)
    assert_equal ["<A:4>\n"], @radio.rx_frames
  end
end
