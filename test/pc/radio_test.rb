class RadioTest < Picotest::Test
  class FakeReport
    def initialize(name)
      @name = name
    end

    def name_include?(prefix)
      @name.include?(prefix)
    end
  end

  def setup
    @radio = StackChan::Controller::Radio.new(name_prefix: "StackChan")
  end

  def notification_packet(handle, value)
    [0xA7, 6 + 4 + value.bytesize, 0, 0, 0, 0, 0, 0, handle, 0, value.bytesize, 0].pack("C*") + value
  end

  def test_pop_and_dispatch_calls_event_popped_even_when_queue_is_empty
    assert_nil @radio.pop_and_dispatch
    assert_equal 1, @radio.event_popped_count
    assert_nil @radio.pop_and_dispatch
    assert_equal 2, @radio.event_popped_count
  end

  def test_a_btstack_1_6_layout_notification_reaches_on_notification_in_one_call
    got = []
    @radio.on_notification = ->(handle, value) { got << [handle, value] }
    @radio.push_pending(notification_packet(0x2A, ".\n"))
    event = @radio.pop_and_dispatch
    assert_equal 0xA7, event.getbyte(0)
    assert_equal [[0x2A, ".\n"]], got
  end

  def test_non_notification_packets_are_returned_but_not_routed
    got = []
    @radio.on_notification = ->(handle, value) { got << [handle, value] }
    @radio.push_pending("\x60\x00")
    assert_equal "\x60\x00", @radio.pop_and_dispatch
    assert_equal [], got
  end

  def test_connect_and_discover_forgets_the_previous_connection_when_no_new_one_completes
    @radio.instance_variable_set(:@conn_handle, 0x40)
    @radio.services << { characteristics: [] }
    @radio.connect_and_discover(15_000)
    assert_equal BLE::HCI_CON_HANDLE_INVALID, @radio.conn_handle
    assert_equal [], @radio.services
  end

  def test_advertising_report_callback_connects_to_first_match_only
    @radio.advertising_report_callback(FakeReport.new("Other"))
    assert_equal 0, @radio.connect_calls.size
    first = FakeReport.new("StackChan-PicoRuby")
    @radio.advertising_report_callback(first)
    @radio.advertising_report_callback(FakeReport.new("StackChan-2"))
    assert_equal 1, @radio.connect_calls.size
    assert_equal first, @radio.connect_calls[0]
    assert_equal first, @radio.target
  end
  def test_the_darwin_disconnect_packet_invalidates_the_handle_and_reports_once
    lost = []
    @radio.on_disconnect = -> { lost << @radio.conn_handle }
    @radio.instance_variable_set(:@conn_handle, 0x40)
    @radio.push_pending([0x3E, 0x01, 0x05].pack("C*"))
    @radio.pop_and_dispatch
    assert_equal BLE::HCI_CON_HANDLE_INVALID, @radio.conn_handle
    assert_equal [BLE::HCI_CON_HANDLE_INVALID], lost
  end

  def test_a_btstack_disconnection_complete_invalidates_the_handle_and_reports_once
    lost = []
    @radio.on_disconnect = -> { lost << @radio.conn_handle }
    @radio.instance_variable_set(:@conn_handle, 0x40)
    @radio.push_pending([0x05, 0x04, 0x00, 0x40, 0x00, 0x13].pack("C*"))
    @radio.pop_and_dispatch
    assert_equal BLE::HCI_CON_HANDLE_INVALID, @radio.conn_handle
    assert_equal [BLE::HCI_CON_HANDLE_INVALID], lost
  end

  def test_an_le_connection_complete_is_not_a_disconnect
    lost = []
    @radio.on_disconnect = -> { lost << :lost }
    @radio.push_pending([0x3E, 0x01, 0x01, 0x00, 0x40, 0x00].pack("C*"))
    @radio.pop_and_dispatch
    assert_equal [], lost
  end
end
