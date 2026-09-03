# The darwin port hands packets to Ruby only inside `_event_popped`, so the
# radio must call it on every poll — not only after the queue already had an
# event (that was the 1 s gate: nothing reached Ruby until the heartbeat).
class StackchanRadioTest < Picotest::Test
  class FakeReport
    def initialize(name)
      @name = name
    end

    def name_include?(prefix)
      @name.include?(prefix)
    end
  end

  def setup
    @radio = StackchanRadio.new(name_prefix: "StackChan")
  end

  # GATT_EVENT_NOTIFICATION layout as StackchanRadio#packet_callback reads it:
  # byte 0 = 0xA7, byte 4 = handle (1 byte), byte 6 = length, bytes 8.. = value.
  def notification_packet(handle, value)
    [0xA7, 0, 0, 0, handle, 0, value.bytesize, 0].pack("C*") + value
  end

  def test_pop_and_dispatch_calls_event_popped_even_when_queue_is_empty
    assert_nil @radio.pop_and_dispatch
    assert_equal 1, @radio.event_popped_count
    assert_nil @radio.pop_and_dispatch
    assert_equal 2, @radio.event_popped_count
  end

  def test_pending_packet_reaches_on_notification_in_one_call
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
    @radio.push_pending("\x05\x00")
    assert_equal "\x05\x00", @radio.pop_and_dispatch
    assert_equal [], got
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
end
