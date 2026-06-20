require_relative "test_helper"
require "stackchan/event"

class TestEventChannel < Test::Unit::TestCase
  def test_push_and_pop
    ch = Stackchan::Event::Channel.new
    ch.push({type: :touch, zone: 1})
    assert_equal({type: :touch, zone: 1}, ch.pop)
  end

  def test_pop_with_timeout_returns_nil_when_empty
    ch = Stackchan::Event::Channel.new
    assert_nil ch.pop(timeout: 0.05)
  end

  def test_each_yields_pushed_events_in_order
    ch = Stackchan::Event::Channel.new
    ch.push(:a)
    ch.push(:b)
    seen = []
    t = Thread.new { ch.each { |e| seen << e; Thread.exit if seen.size == 2 } }
    t.join(0.5)
    assert_equal [:a, :b], seen
  end
end

class TestEventTouchReader < Test::Unit::TestCase
  class FakeBLEClient
    attr_accessor :on_unsolicited
  end

  def test_start_wires_touch_callback
    client = FakeBLEClient.new
    channel = Stackchan::Event::Channel.new
    Stackchan::Event::TouchReader.new(client, channel).start
    client.on_unsolicited.call("<touch:2>\n")
    assert_equal({type: :touch, zone: 2}, channel.pop)
  end

  def test_non_touch_frame_is_ignored
    client = FakeBLEClient.new
    channel = Stackchan::Event::Channel.new
    Stackchan::Event::TouchReader.new(client, channel).start
    client.on_unsolicited.call(".\n")
    assert_nil channel.pop(timeout: 0.05)
  end
end
