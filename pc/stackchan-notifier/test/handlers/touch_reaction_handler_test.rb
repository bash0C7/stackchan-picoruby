require_relative "../helper"
require "stackchan_notifier/handlers/touch_reaction_handler"

class TouchReactionHandlerTest < Test::Unit::TestCase
  class FakeSession
    def initialize(reply: nil, error: nil); @reply = reply; @error = error; end
    def respond(to:)
      raise @error if @error
      @reply
    end
  end

  class FakeClient
    attr_reader :sent
    def initialize; @sent = []; end
    def raw_send(frame); @sent << frame; self; end
  end

  def setup
    @client = FakeClient.new
    @ctx    = { ts: nil, restore_sleep_fn: ->(s) {} }
  end

  def test_zone_themed_reply_emits_face_and_text_frame
    session = FakeSession.new(reply: "[joy]うれしい")
    handler = StackchanNotifier::Handlers::TouchReactionHandler.new(session: session)
    handler.deliver(client: @client, params: { zone: 0 }, ctx: @ctx)
    assert_equal ["<F:2,text:うれしい>\n"], @client.sent
  end

  def test_unknown_zone_still_reacts_with_fallback_face
    session = FakeSession.new(reply: "やあ") # no tag -> fallback face (neutral=0)
    handler = StackchanNotifier::Handlers::TouchReactionHandler.new(session: session)
    handler.deliver(client: @client, params: { zone: 99 }, ctx: @ctx)
    assert_equal ["<F:0,text:やあ>\n"], @client.sent
  end

  def test_generation_error_emits_sad_fallback
    session = FakeSession.new(error: AppleFoundationModel::GenerationError.new("boom"))
    handler = StackchanNotifier::Handlers::TouchReactionHandler.new(session: session)
    handler.deliver(client: @client, params: { zone: 1 }, ctx: @ctx)
    assert_equal ["<F:4,text:うまく考えられませんでした>\n"], @client.sent
  end
end
