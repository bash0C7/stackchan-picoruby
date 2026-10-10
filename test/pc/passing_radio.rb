class PassingRadio < FakeRobotRadio
  def before_drx_write(_value)
    Task.pass
    :continue
  end
end
