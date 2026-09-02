class StackchanCentralTest < Picotest::Test
  RX   = 0x11
  TX   = 0x14
  CCCD = 0x16

  def nus_services
    [{ characteristics: [
      { uuid128: NusResolver.rx_uuid, value_handle: RX, descriptors: [] },
      { uuid128: NusResolver.tx_uuid, value_handle: TX,
        descriptors: [{ uuid128: NusResolver.cccd_uuid, handle: CCCD }] },
    ] }]
  end

  def build_central(radio)
    StackchanCentral.new(
      name_prefix: "StackChan",
      radio: radio,
      log_fn: ->(line) { @logs << line },
    )
  end

  def setup
    FakeClock.reset(1000)
    @logs = []
    @radio = FakeRadio.new(services: nus_services)
    @central = build_central(@radio)
    @central.connect
    FakeClock.sleeps.clear
    @logs.clear
  end

  def ack_timeout_polls
    StackchanCentral::ACK_TIMEOUT_MS / StackchanCentral::POLLING_UNIT_MS
  end

  # --- connect ---

  def test_connect_subscribes_tx_and_settles_200ms
    radio = FakeRadio.new(services: nus_services)
    sleeps_before = FakeClock.sleeps.size
    build_central(radio).connect
    assert_equal [[CCCD, "\x01\x00"]], radio.descriptor_writes
    total = 0
    FakeClock.sleeps[sleeps_before, FakeClock.sleeps.size].each { |ms| total += ms }
    assert_equal StackchanCentral::SUBSCRIBE_SETTLE_MS, total
    assert_equal 1, radio.connect_and_discover_calls
  end

  def test_connect_without_advertiser_raises
    radio = FakeRadio.new(services: nus_services, target: nil)
    assert_raise(Stackchan::BLE::ConnectionError) { build_central(radio).connect }
  end

  def test_connect_without_nus_raises
    radio = FakeRadio.new(services: [])
    assert_raise(Stackchan::BLE::ConnectionError) { build_central(radio).connect }
  end

  def test_not_connected_raises
    central = build_central(FakeRadio.new(services: nus_services))
    assert_raise(Stackchan::BLE::ConnectionError) { central.raw_send("<F:2>\n") }
  end

  # --- ACK wait ---

  def test_raw_send_returns_on_first_drain_without_sleeping
    @radio.schedule_notification(TX, ".\n", after_polls: 1)
    @central.raw_send("<F:2>\n")
    assert_equal [[RX, "<F:2>\n"]], @radio.writes
    assert_equal [], FakeClock.sleeps
    assert_equal ["[t] <F:2> ack=0ms"], @logs
  end

  def test_raw_send_polls_every_20ms_until_the_ack_arrives
    @radio.schedule_notification(TX, ".\n", after_polls: 3)
    @central.raw_send("<F:2>\n")
    assert_equal [20, 20], FakeClock.sleeps
    assert_equal ["[t] <F:2> ack=40ms"], @logs
  end

  def test_ack_timeout_after_3000ms_of_polling
    assert_raise(Stackchan::BLE::TimeoutError) { @central.raw_send("<F:2>\n") }
    assert_equal ack_timeout_polls, FakeClock.sleeps.size
    total = 0
    FakeClock.sleeps.each { |ms| total += ms }
    assert_equal StackchanCentral::ACK_TIMEOUT_MS, total
    assert_equal ["[t] <F:2> ack=timeout"], @logs
  end

  def test_error_ack_raises_device_error
    @radio.schedule_notification(TX, "?\n", after_polls: 1)
    assert_raise(Stackchan::BLE::DeviceError) { @central.raw_send("<F:2>\n") }
  end

  def test_servo_frame_waits_for_the_detail_frame
    @radio.schedule_notification(TX, ".\n", after_polls: 1)
    @radio.schedule_notification(TX, "<YL_actual:0,PU_actual:0>\n", after_polls: 5)
    @central.raw_send("<YL:0,PU:0,T:300>\n")
    assert_equal "<YL_actual:0,PU_actual:0>\n", @central.last_detail_frame
    assert_equal [20, 20], FakeClock.sleeps
    assert_equal ["[t] <YL:0,PU:0,T:300> ack=0ms detail=40ms"], @logs
  end

  def test_detail_timeout_is_named_in_the_timing_log
    @radio.schedule_notification(TX, ".\n", after_polls: 1)   # ACK arrives, detail never does
    @central.raw_send("<YL:0,PU:0,T:300>\n")
    assert_nil @central.last_detail_frame
    assert_equal ack_timeout_polls, FakeClock.sleeps.size
    assert_equal ["[t] <YL:0,PU:0,T:300> ack=0ms detail=timeout"], @logs
  end

  def test_detail_only_response_is_kept_as_detail
    @radio.schedule_notification(TX, "<yaw_raw:12,pitch_raw:34>\n", after_polls: 1)
    @central.raw_send("<read:pos>\n")
    assert_equal "<yaw_raw:12,pitch_raw:34>\n", @central.last_detail_frame
    assert_equal ["[t] <read:pos> ack=0ms"], @logs
  end

  def test_touch_notification_goes_to_on_unsolicited_not_inbox
    got = []
    @central.on_unsolicited = ->(frame) { got << frame }
    @radio.schedule_notification(TX, "<touch:1>\n", after_polls: 1)
    @radio.schedule_notification(TX, ".\n", after_polls: 2)
    @central.raw_send("<F:2>\n")
    assert_equal ["<touch:1>\n"], got
    assert_equal [], FakeClock.sleeps
  end

  def test_drain_consumes_a_burst_in_one_poll_step
    got = []
    @central.on_unsolicited = ->(frame) { got << frame }
    @radio.schedule_notification(TX, "<touch:0>\n", after_polls: 1)
    @radio.schedule_notification(TX, "<touch:2>\n", after_polls: 1)
    @radio.schedule_notification(TX, ".\n", after_polls: 1)
    @central.raw_send("<F:2>\n")
    assert_equal ["<touch:0>\n", "<touch:2>\n"], got
    assert_equal [], FakeClock.sleeps
  end

  def test_send_awaits_one_ack_per_builder_frame
    @radio.schedule_notification(TX, ".\n", after_polls: 1)
    @radio.schedule_notification(TX, ".\n", after_polls: 3)
    @central.send { |s| s.face(:joy); s.torque(on: true) }
    assert_equal [[RX, "<F:2>\n"], [RX, "<torque:on>\n"]], @radio.writes
  end

  def test_write_without_ack_writes_rx_and_waits_for_nothing
    @central.write_without_ack("abc")
    assert_equal [[RX, "abc"]], @radio.writes
    assert_equal [], FakeClock.sleeps
    assert_equal [], @logs
  end

  # --- audio done ---

  def test_audio_done_timeout_ms_clamps_to_floor_and_cap
    assert_equal 30_000,  @central.audio_done_timeout_ms(240)
    assert_equal 75_300,  @central.audio_done_timeout_ms(60_000)
    assert_equal 180_000, @central.audio_done_timeout_ms(200_000)
  end

  def test_await_audio_done_returns_when_the_frame_arrives
    @radio.schedule_notification(TX, "<A:done>\n", after_polls: 3)
    assert_equal @central, @central.await_audio_done(240)
    assert_equal [20, 20], FakeClock.sleeps
  end

  def test_await_audio_done_times_out_after_the_budget
    assert_raise(Stackchan::BLE::TimeoutError) { @central.await_audio_done(240) }
    assert_equal 30_000 / StackchanCentral::POLLING_UNIT_MS, FakeClock.sleeps.size
  end
end
