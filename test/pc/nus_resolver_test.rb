# NusResolver is pure (UUID -> handle lookup, frame classification) and is
# the first thing the pc suite loads, so it doubles as the suite's smoke test.
class NusResolverTest < Picotest::Test
  def services
    [
      { characteristics: [{ uuid128: "other", value_handle: 3, descriptors: [] }] },
      { characteristics: [
        { uuid128: NusResolver.rx_uuid, value_handle: 0x11, descriptors: [] },
        { uuid128: NusResolver.tx_uuid, value_handle: 0x14,
          descriptors: [{ uuid128: "x", handle: 0x15 }, { uuid128: NusResolver.cccd_uuid, handle: 0x16 }] },
      ] },
    ]
  end

  def test_find_characteristic_across_services
    assert_equal 0x11, NusResolver.find_characteristic(services, NusResolver.rx_uuid)[:value_handle]
    assert_equal 0x14, NusResolver.find_characteristic(services, NusResolver.tx_uuid)[:value_handle]
    assert_nil NusResolver.find_characteristic(services, "missing")
  end

  def test_cccd_handle_of_tx_and_nil_otherwise
    tx = NusResolver.find_characteristic(services, NusResolver.tx_uuid)
    rx = NusResolver.find_characteristic(services, NusResolver.rx_uuid)
    assert_equal 0x16, NusResolver.cccd_handle(tx)
    assert_nil NusResolver.cccd_handle(rx)
    assert_nil NusResolver.cccd_handle(nil)
  end

  def test_classify
    assert_equal :touch,  NusResolver.classify("<touch:2>\n")
    assert_equal :ack,    NusResolver.classify(".\n")
    assert_equal :ack,    NusResolver.classify("?\n")
    assert_equal :detail, NusResolver.classify("<YL_actual:1,PU_actual:2>\n")
    assert_equal :detail, NusResolver.classify("<yaw_raw:1,pitch_raw:2>\n")
    assert_equal :other,  NusResolver.classify("<rx:ok>\n")
  end
end
