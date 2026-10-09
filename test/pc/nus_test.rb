class NusTest < Picotest::Test
  def services
    [
      { characteristics: [{ uuid128: "other", value_handle: 3, descriptors: [] }] },
      { characteristics: [
        { uuid128: StackChan::Controller::Nus.rx_uuid, value_handle: 0x11, descriptors: [] },
        { uuid128: StackChan::Controller::Nus.tx_uuid, value_handle: 0x14,
          descriptors: [{ uuid128: "x", handle: 0x15 }, { uuid128: StackChan::Controller::Nus.cccd_uuid, handle: 0x16 }] },
      ] },
    ]
  end

  def test_find_characteristic_across_services
    assert_equal 0x11, StackChan::Controller::Nus.find_characteristic(services, StackChan::Controller::Nus.rx_uuid)[:value_handle]
    assert_equal 0x14, StackChan::Controller::Nus.find_characteristic(services, StackChan::Controller::Nus.tx_uuid)[:value_handle]
    assert_nil StackChan::Controller::Nus.find_characteristic(services, "missing")
  end

  def test_cccd_handle_of_tx_and_nil_otherwise
    tx = StackChan::Controller::Nus.find_characteristic(services, StackChan::Controller::Nus.tx_uuid)
    rx = StackChan::Controller::Nus.find_characteristic(services, StackChan::Controller::Nus.rx_uuid)
    assert_equal 0x16, StackChan::Controller::Nus.cccd_handle(tx)
    assert_nil StackChan::Controller::Nus.cccd_handle(rx)
    assert_nil StackChan::Controller::Nus.cccd_handle(nil)
  end
end
