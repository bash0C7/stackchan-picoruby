$LOAD_PATH.unshift(File.expand_path('.', __dir__))
require 'test_helper'

class SCServoTest < Test::Unit::TestCase
  def test_initializes_with_uart_and_id
    uart = FakeUART.new
    servo = SCServo.new(uart, id: 1)
    assert_kind_of SCServo, servo
  end
end
