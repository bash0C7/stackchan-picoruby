require "helper"
require "stackchan_notifier/handlers/servo_handler"

class ServoHandlerTest < Test::Unit::TestCase
  def test_deliver_yaw_pitch_time
    client = FakeBleClient.new
    handler = StackchanNotifier::Handlers::ServoHandler.new
    handler.deliver(
      client: client,
      params: { yaw_left: 50, yaw_right: nil, pitch_up: 50, time_ms: 2000, velocity: nil },
      ctx: {},
    )
    assert_equal 1, client.sent.size
    cmds = client.sent[0]
    assert_equal [{ kind: :head, yaw_left: 50, yaw_right: nil, pitch_up: 50, time_ms: 2000, velocity: nil }], cmds
  end

  def test_deliver_yaw_left_only_with_velocity
    client = FakeBleClient.new
    handler = StackchanNotifier::Handlers::ServoHandler.new
    handler.deliver(
      client: client,
      params: { yaw_left: 100, yaw_right: nil, pitch_up: nil, time_ms: nil, velocity: 50 },
      ctx: {},
    )
    assert_equal [{ kind: :head, yaw_left: 100, yaw_right: nil, pitch_up: nil, time_ms: nil, velocity: 50 }], client.sent[0]
  end
end
