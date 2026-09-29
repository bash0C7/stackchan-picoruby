class DaemonTasksTest < Picotest::Test
  PASSES = 10

  def setup
    FakeClock.reset(0)
    DRb.reset_stop_service_calls
    @ble = FakeStoppableBle.new
    link = StackChan::Controller::Link.new(central: @ble, clock: -> { FakeClock.now }, log: ->(line) {})
    @daemon = StackChan::Controller::Daemon.new(link: link, central: @ble, log: ->(line) {})
    @tasks = []
  end

  def teardown
    i = 0
    while i < @tasks.size
      @tasks[i].terminate
      i += 1
    end
  end

  def pass_tasks
    i = 0
    while i < PASSES
      Task.pass
      i += 1
    end
  end

  def test_the_tick_task_keeps_ticking_past_its_first_tick
    tick = @daemon.__send__(:start_tick)
    @tasks << tick
    pass_tasks
    assert_false tick.value.is_a?(NoMethodError)
    assert_true FakeClock.sleeps.size >= 2
  end

  def test_stop_disconnects_the_link_and_stops_drb_once_the_reply_wait_is_over
    @daemon.instance_variable_set(:@tick_task, Task.new(name: "tick") {})
    @daemon.stop
    @tasks << @daemon.instance_variable_get(:@shutdown_task)
    pass_tasks
    assert_equal 1, @ble.disconnect_calls
    assert_equal 1, DRb.stop_service_calls
  end
end
