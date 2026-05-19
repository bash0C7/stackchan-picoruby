require 'uart'

class SCServo
  HEADER          = [0xFF, 0xFF].freeze
  INSTR_PING      = 0x01
  INSTR_READ      = 0x02
  INSTR_WRITE     = 0x03
  REG_TORQUE      = 0x28
  REG_GOAL_POS_L  = 0x2A  # GoalPos(2) + Time(2) + Speed(2) bundled write
  REG_MODE        = 0x21  # 0 = position, 1 = PWM
  REG_PRESENT_POS_L = 0x38
  READ_TIMEOUT_MS = 50
  DRAIN_TIMEOUT_MS = 5
  DRAIN_BUDGET_BYTES = 64

  def initialize(uart, id:)
    @uart = uart
    @id   = id
  end
end
