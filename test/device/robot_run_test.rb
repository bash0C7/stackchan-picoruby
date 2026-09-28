ROBOT_RUN_LOG = []

class StackChan::Robot
  def sleep_ms(ms)
    ROBOT_RUN_LOG << [:sleep, ms]
  end
end

class RobotRunTest < Picotest::Test
  class FakeBoot
    def self.run
      ROBOT_RUN_LOG << [:boot]
      { display: :display, led: :led, head: :head, touch: :touch, speaker: :speaker }
    end
  end

  class FakePeripheral
    attr_reader :robot_handle

    def initialize(robot, display:, led:, head:, touch:, speaker:)
      ROBOT_RUN_LOG << [:peripheral, display, led, head, touch, speaker]
      @robot_handle = :handle
    end

    def run
      ROBOT_RUN_LOG << [:run]
    end
  end

  def setup
    ROBOT_RUN_LOG.clear
  end

  def robot
    StackChan.robot do |bot|
      bot.face :neutral
      bot.face :closed, eyes: :closed, mouth: :none
      bot.on_boot { |r| ROBOT_RUN_LOG << [:on_boot, r] }
    end
  end

  def test_serve_boots_waits_then_starts_the_peripheral_after_on_boot
    robot.serve(FakeBoot, FakePeripheral)
    assert_equal [
      [:sleep, 5000],
      [:boot],
      [:sleep, 3000],
      [:peripheral, :display, :led, :head, :touch, :speaker],
      [:on_boot, :handle],
      [:run],
    ], ROBOT_RUN_LOG
  end
end
