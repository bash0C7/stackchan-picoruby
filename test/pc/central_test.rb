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
