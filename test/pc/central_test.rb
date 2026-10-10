class CentralTest < Picotest::Test
  DRX  = 0x21
  DTX  = 0x24
  DCCCD = 0x26

  def nus_services
    [{ characteristics: [
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

  def test_connect_subscribes_the_drb_tx_and_settles_200ms
    radio = FakeRadio.new(services: nus_services)
    sleeps_before = FakeClock.sleeps.size
    build_central(radio).connect
    assert_equal [[DCCCD, "\x01\x00"]], radio.descriptor_writes
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

  def test_connect_whose_discovery_stopped_before_the_drb_cccd_raises_and_subscribes_nothing
    radio = FakeRadio.new(services: services_without_cccd(StackChan::Controller::Nus.drb_tx_uuid))
    assert_raise(StackChan::Controller::ConnectionError) { build_central(radio).connect }
    assert_equal [], radio.descriptor_writes
  end

  def connect_error_message(radio)
    build_central(radio).connect
    nil
  rescue StackChan::Controller::ConnectionError => e
    e.message
  end

  def gap_uuid
    [0x00, 0x00, 0x2a, 0x00, 0x00, 0x00, 0x10, 0x00,
     0x80, 0x00, 0x00, 0x80, 0x5f, 0x9b, 0x34, 0xfb].pack("C*")
  end

  def test_connect_with_empty_discovery_says_nothing_was_discovered
    message = connect_error_message(FakeRadio.new(services: []))
    assert_equal "dRuby pair not found; discovered services=0 characteristics=none", message
  end

  def test_connect_with_foreign_table_lists_the_characteristics_found
    nus = StackChan::Controller::Nus
    services = [
      { characteristics: [{ uuid128: gap_uuid, value_handle: 3, descriptors: [] }] },
      { characteristics: [
        { uuid128: nus.nus_uuid(0x00, 0x03), value_handle: 5, descriptors: [] },
        { uuid128: nus.nus_uuid(0x00, 0x02), value_handle: 7, descriptors: [] },
      ] },
    ]
    message = connect_error_message(FakeRadio.new(services: services))
    assert_equal "dRuby pair not found; discovered services=2 characteristics=2a00,6e400003,6e400002", message
  end

  def test_connect_without_drb_cccd_reports_the_discovery
    radio = FakeRadio.new(services: services_without_cccd(StackChan::Controller::Nus.drb_tx_uuid))
    message = connect_error_message(radio)
    assert_equal "dRuby TX CCCD not found; discovery did not finish; discovered services=1 characteristics=6e400004,6e400005", message
  end

  def test_not_connected_raises
    central = build_central(FakeRadio.new(services: nus_services))
    assert_raise(StackChan::Controller::ConnectionError) { central.raw_send("<F:2>\n") }
  end

  def test_audio_done_timeout_ms_clamps_to_floor_and_cap
    assert_equal 30_000,  @central.audio_done_timeout_ms(240)
    assert_equal 75_300,  @central.audio_done_timeout_ms(60_000)
    assert_equal 180_000, @central.audio_done_timeout_ms(200_000)
  end
end
