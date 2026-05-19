require "helper"
require "stackchan_notifier/handlers/raw_handler"

class RawHandlerTest < Test::Unit::TestCase
  def test_deliver_appends_newline_if_missing
    client = FakeBleClient.new
    handler = StackchanNotifier::Handlers::RawHandler.new
    handler.deliver(
      client: client,
      params: { frame: "<F:2>" },
      ctx: {},
    )
    assert_equal [{ kind: :raw_send, frame: "<F:2>\n" }], client.sent
  end

  def test_deliver_preserves_trailing_newline
    client = FakeBleClient.new
    handler = StackchanNotifier::Handlers::RawHandler.new
    handler.deliver(
      client: client,
      params: { frame: "<L:1,R:0,G:255,B:0,S:B,M:s>\n" },
      ctx: {},
    )
    assert_equal [{ kind: :raw_send, frame: "<L:1,R:0,G:255,B:0,S:B,M:s>\n" }], client.sent
  end
end
