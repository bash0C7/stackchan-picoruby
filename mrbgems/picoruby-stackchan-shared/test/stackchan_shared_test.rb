class StackchanSharedTest < Picotest::Test
  def test_send_builder_keeps_one_frame_per_key_in_first_occurrence_order
    b = Stackchan::BLE::SendBuilder.new
    b.face(:smile)
    b.led(:green, side: :both, mode: :solid)
    b.led(:red, side: :left, mode: :blink)
    b.head(yaw_left: 40, pitch_up: 10, time_ms: 300)
    expected = [
      "<F:1>\n",
      "<L:1,R:0,G:255,B:0,S:B,M:s>\n",
      "<L:1,R:255,G:0,B:0,S:R,M:b>\n",
      "<YL:40,PU:10,T:300>\n",
    ]
    assert_equal expected, b.to_frames
  end

  def test_send_builder_rewriting_an_earlier_key_keeps_its_first_position
    b = Stackchan::BLE::SendBuilder.new
    b.face(:smile)
    b.led(:blue)
    b.face(:sad)
    assert_equal ["<F:4>\n", "<L:1,R:0,G:0,B:255,S:B,M:s>\n"], b.to_frames
  end

  def test_send_builder_rejects_an_unknown_led_color
    assert_raise(ArgumentError) { Stackchan::BLE::SendBuilder.new.led(:rgb) }
  end

  def test_ble_error_hierarchy
    assert Stackchan::BLE::TimeoutError.ancestors.include?(Stackchan::BLE::Error)
    assert Stackchan::BLE::DeviceError.ancestors.include?(Stackchan::BLE::Error)
    assert Stackchan::BLE::ConnectionError.ancestors.include?(Stackchan::BLE::Error)
    assert Stackchan::BLE::Error.ancestors.include?(StandardError)
  end
end
