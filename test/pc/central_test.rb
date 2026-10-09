class CentralTest < Picotest::Test
  RX   = 0x11
  TX   = 0x14
  CCCD = 0x16
  DRX  = 0x21
  DTX  = 0x24
  DCCCD = 0x26

  def nus_services
    [{ characteristics: [
      { uuid128: StackChan::Controller::Nus.rx_uuid, value_handle: RX, descriptors: [] },
      { uuid128: StackChan::Controller::Nus.tx_uuid, value_handle: TX,
        descriptors: [{ uuid128: StackChan::Controller::Nus.cccd_uuid, handle: CCCD }] },
      { uuid128: StackChan::Controller::Nus.drb_rx_uuid, value_handle: DRX, descriptors: [] },
      { uuid128: StackChan::Controller::Nus.drb_tx_uuid, value_handle: DTX,
        descriptors: [{ uuid128: StackChan::Controller::Nus.cccd_uuid, handle: DCCCD }] },
    ] }]
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
    @radio = FakeRadio.new(services: nus_services)
    @central = build_central(@radio)
    @central.connect
    FakeClock.sleeps.clear
    @logs.clear
  end

  def ack_timeout_polls
    StackChan::Controller::Central::ACK_TIMEOUT_MS / StackChan::Controller::Central::POLLING_UNIT_MS
  end

  def test_connect_subscribes_tx_and_settles_200ms
    radio = FakeRadio.new(services: nus_services)
    sleeps_before = FakeClock.sleeps.size
    build_central(radio).connect
    assert_equal [[CCCD, "\x01\x00"], [DCCCD, "\x01\x00"]], radio.descriptor_writes
    total = 0
    FakeClock.sleeps[sleeps_before, FakeClock.sleeps.size].each { |ms| total += ms }
    assert_equal StackChan::Controller::Central::SUBSCRIBE_SETTLE_MS, total
    assert_equal 1, radio.connect_and_discover_calls
  end

  def test_connect_without_advertiser_raises
    radio = FakeRadio.new(services: nus_services, target: nil)
    assert_raise(StackChan::Controller::ConnectionError) { build_central(radio).connect }
  end

  def test_connect_without_nus_raises
    radio = FakeRadio.new(services: [])
    assert_raise(StackChan::Controller::ConnectionError) { build_central(radio).connect }
  end

  def services_without_cccd(uuid)
    services = nus_services
    services[0][:characteristics].each { |c| c[:descriptors] = [] if c[:uuid128] == uuid }
    services
  end

  def test_connect_whose_discovery_stopped_before_the_tx_cccd_raises_and_subscribes_nothing
    radio = FakeRadio.new(services: services_without_cccd(StackChan::Controller::Nus.tx_uuid))
    assert_raise(StackChan::Controller::ConnectionError) { build_central(radio).connect }
    assert_equal [], radio.descriptor_writes
  end

  def test_connect_whose_discovery_stopped_before_the_drb_cccd_raises_and_subscribes_nothing
    radio = FakeRadio.new(services: services_without_cccd(StackChan::Controller::Nus.drb_tx_uuid))
    assert_raise(StackChan::Controller::ConnectionError) { build_central(radio).connect }
    assert_equal [], radio.descriptor_writes
  end

  def test_not_connected_raises
    central = build_central(FakeRadio.new(services: nus_services))
    assert_raise(StackChan::Controller::ConnectionError) { central.raw_send("<F:2>\n") }
  end

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
    assert_raise(StackChan::Controller::TimeoutError) { @central.raw_send("<F:2>\n") }
    assert_equal ack_timeout_polls, FakeClock.sleeps.size
    total = 0
    FakeClock.sleeps.each { |ms| total += ms }
    assert_equal StackChan::Controller::Central::ACK_TIMEOUT_MS, total
    assert_equal ["[t] <F:2> ack=timeout"], @logs
  end

  def test_error_ack_raises_device_error
    @radio.schedule_notification(TX, "?\n", after_polls: 1)
    assert_raise(StackChan::Controller::DeviceError) { @central.raw_send("<F:2>\n") }
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
    @radio.schedule_notification(TX, ".\n", after_polls: 1)
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
    assert_raise(StackChan::Controller::TimeoutError) { @central.await_audio_done(240) }
    assert_equal 30_000 / StackChan::Controller::Central::POLLING_UNIT_MS, FakeClock.sleeps.size
  end
end
