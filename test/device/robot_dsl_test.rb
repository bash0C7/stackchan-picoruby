class RobotDslTest < Picotest::Test
  class DslTouch
    attr_accessor :next_zone

    def initialize
      @next_zone = nil
    end

    def poll
      z = @next_zone
      @next_zone = nil
      z
    end
  end

  class DslServo
    attr_reader :writes
    def initialize; @writes = []; end
    def write_pos(pos, time_ms:, speed:); @writes << [pos, time_ms, speed]; end
    def read_pos; 0; end
  end

  class DslSink
    attr_reader :writes
    def initialize; @writes = []; end
    def write(b); @writes << b; end
  end

  def setup
    @display  = FakeDisplay.new
    @led      = FakeLed.new
    @touch    = DslTouch.new
    @yaw      = DslServo.new
    @pitch    = DslServo.new
    @stdout   = DslSink.new
    @notified = []
    @booted   = []
  end

  def base_faces(bot)
    bot.face :neutral
    bot.face :closed, eyes: :closed, mouth: :none
  end

  def full_robot
    booted = @booted
    StackChan.robot do |bot|
      base_faces(bot)
      bot.face :smile, mouth: 8
      bot.face_index "1" => :smile
      bot.on_boot { |r| booted << r }
      bot.on_touch(:right) { |r| r.led(:right, [60, 0, 0], flash: 300) }
      bot.on_frame("X") { |r, value| r.head(yaw_left: value.to_i, time: 100) }
      bot.remote(:wave) { |r, n| r.led(:both, [n, n, n]); [:waved, n] }
      bot.every(1000) { |r| r.led(:left, [0, 0, 9], mode: :breathing) }
    end
  end

  def wire(robot)
    notified = @notified
    robot.wire(
      display: @display, led: @led, touch: @touch,
      head: StackChan::Robot::Head.new(@yaw, @pitch),
      stdout: @stdout, notify: ->(frame) { notified << frame }
    )
  end

  def led_calls(kind)
    @led.calls.select { |c| c.first == kind }.map(&:last)
  end

  def test_robot_returns_a_robot
    assert_equal StackChan::Robot, full_robot.class
  end

  def test_a_frame_handler_moves_the_head_through_the_dispatcher
    w = wire(full_robot)
    w.dispatcher.handle({ "X" => "50" })
    assert_equal [[332, 100, 0]], @yaw.writes
    assert_equal [".\n"], @stdout.writes
  end

  def test_a_touch_handler_flashes_through_the_ticker_and_notifies
    w = wire(full_robot)
    @touch.next_zone = 1
    w.ticker.tick(0)
    assert_equal [[:right, 60, 0, 0, 300]], led_calls(:flash_side)
    assert_equal ["<touch:1>\n"], @notified
  end

  def test_a_remote_handler_is_exposed_and_reached_with_its_arguments
    w = wire(full_robot)
    assert w.remote.exposed.include?(:wave)
    assert_equal [:waved, 7], w.remote.__send__(:wave, 7)
    assert_equal [[:both, 7, 7, 7, :solid]], led_calls(:animate_side)
  end

  def test_an_every_handler_fires_one_period_after_the_first_tick
    w = wire(full_robot)
    w.ticker.tick(0)
    w.ticker.tick(999)
    assert_equal [], led_calls(:animate_side)
    w.ticker.tick(1000)
    assert_equal [[:left, 0, 0, 9, :breathing]], led_calls(:animate_side)
  end

  def test_on_boot_handlers_run_in_order_with_the_handle
    order = []
    robot = StackChan.robot do |bot|
      base_faces(bot)
      bot.on_boot { |r| order << [:first, r] }
      bot.on_boot { |r| order << [:second, r] }
    end
    w = wire(robot)
    robot.run_on_boot(w.handle)
    assert_equal [[:first, w.handle], [:second, w.handle]], order
  end

  def test_the_handle_is_the_dispatchers_handle
    w = wire(full_robot)
    assert_equal w.dispatcher.robot_handle, w.handle
  end

  def test_face_index_maps_the_wire_index_to_the_defined_face
    w = wire(full_robot)
    w.dispatcher.handle({ "F" => "1" })
    assert_equal 8, w.dispatcher.current_face.mouth
  end

  def test_a_redefined_face_overrides_the_earlier_one
    robot = StackChan.robot do |bot|
      base_faces(bot)
      bot.face :neutral, mouth: 5
    end
    assert_equal 5, wire(robot).dispatcher.current_face.mouth
  end

  def test_face_index_may_name_a_face_defined_later
    robot = StackChan.robot do |bot|
      bot.face_index "9" => :late
      base_faces(bot)
      bot.face :late, mouth: 3
    end
    w = wire(robot)
    w.dispatcher.handle({ "F" => "9" })
    assert_equal 3, w.dispatcher.current_face.mouth
  end

  def test_touch_zones_map_back_right_left_to_0_1_2
    got = []
    robot = StackChan.robot do |bot|
      base_faces(bot)
      bot.on_touch(:back)  { |_r| got << :back }
      bot.on_touch(:right) { |_r| got << :right }
      bot.on_touch(:left)  { |_r| got << :left }
    end
    w = wire(robot)
    @touch.next_zone = 0
    w.ticker.tick(0)
    @touch.next_zone = 1
    w.ticker.tick(50)
    @touch.next_zone = 2
    w.ticker.tick(100)
    assert_equal [:back, :right, :left], got
  end

  def test_the_app_touch_and_blink_tables_reproduce_the_hand_built_ones
    robot = StackChan.robot do |bot|
      bot.face :neutral
      bot.face :surprised, mouth: :open
      bot.face :closed, eyes: :closed, mouth: :none
      bot.on_touch(:back) { |r| r.face(:surprised); r.led(:both, [0, 60, 0], flash: 300) }
      bot.every(5000) { |r| r.blink(150) }
    end
    w = wire(robot)
    @touch.next_zone = 0
    w.ticker.tick(0)
    assert_equal :open, w.dispatcher.current_face.mouth
    assert_equal [[:both, 0, 60, 0, 300]], led_calls(:flash_side)
    @display.calls.clear
    w.ticker.tick(5000)
    assert_equal [:draw_rect, :draw_rect, :draw_line, :draw_line], @display.calls.map(&:first)
  end

  def test_robot_without_a_block_raises
    assert_raise(ArgumentError) { StackChan.robot }
  end

  def test_missing_neutral_raises
    assert_raise(ArgumentError) do
      StackChan.robot { |bot| bot.face :closed, eyes: :closed, mouth: :none }
    end
  end

  def test_missing_closed_raises
    assert_raise(ArgumentError) { StackChan.robot { |bot| bot.face :neutral } }
  end

  def test_face_index_naming_an_undefined_face_raises
    assert_raise(ArgumentError) do
      StackChan.robot do |bot|
        base_faces(bot)
        bot.face_index "7" => :wink
      end
    end
  end

  def test_bad_face_geometry_raises_at_definition
    assert_raise(ArgumentError) { StackChan.robot { |bot| bot.face :odd, bogus: 1 } }
  end

  def test_an_unknown_touch_zone_raises
    assert_raise(ArgumentError) do
      StackChan.robot { |bot| base_faces(bot); bot.on_touch(:front) { |_r| } }
    end
  end

  def test_on_frame_with_an_engine_key_raises
    keys = %w[torque selftest read F L text YL YR PU T V M S R G B A]
    i = 0
    while i < keys.size
      key = keys[i]
      assert_raise(ArgumentError) do
        StackChan.robot { |bot| base_faces(bot); bot.on_frame(key) { |_r, _v| true } }
      end
      i += 1
    end
  end

  def test_on_frame_with_a_non_string_key_raises
    assert_raise(ArgumentError) do
      StackChan.robot { |bot| base_faces(bot); bot.on_frame(:X) { |_r, _v| true } }
    end
  end

  def test_remote_shadowing_a_built_in_raises
    assert_raise(ArgumentError) do
      StackChan.robot { |bot| base_faces(bot); bot.remote(:face) { |_r| } }
    end
  end

  def test_remote_shadowing_an_object_method_raises
    assert_raise(ArgumentError) do
      StackChan.robot { |bot| base_faces(bot); bot.remote(:inspect) { |_r| } }
    end
  end

  def test_remote_shadowing_a_private_kernel_method_raises
    assert_raise(ArgumentError) do
      StackChan.robot { |bot| base_faces(bot); bot.remote(:puts) { |_r| } }
    end
  end

  def test_remote_with_a_string_name_raises
    assert_raise(ArgumentError) do
      StackChan.robot { |bot| base_faces(bot); bot.remote("wave") { |_r| } }
    end
  end

  def test_every_with_a_non_positive_period_raises
    assert_raise(ArgumentError) do
      StackChan.robot { |bot| base_faces(bot); bot.every(0) { |_r| } }
    end
  end

  def test_every_with_a_non_integer_period_raises
    assert_raise(ArgumentError) do
      StackChan.robot { |bot| base_faces(bot); bot.every(1.5) { |_r| } }
    end
  end

  def test_release_after_is_stored_on_the_robot
    robot = StackChan.robot { |bot| base_faces(bot); bot.release_after 15_000 }
    assert_equal 15_000, robot.release_after
  end

  def test_without_release_after_the_robot_never_releases
    robot = StackChan.robot { |bot| base_faces(bot) }
    assert_nil robot.release_after
  end

  def test_release_after_with_a_non_positive_period_raises
    assert_raise(ArgumentError) { StackChan.robot { |bot| base_faces(bot); bot.release_after 0 } }
    assert_raise(ArgumentError) { StackChan.robot { |bot| base_faces(bot); bot.release_after(-1) } }
  end

  def test_release_after_with_a_non_integer_period_raises
    assert_raise(ArgumentError) { StackChan.robot { |bot| base_faces(bot); bot.release_after 1.5 } }
    assert_raise(ArgumentError) { StackChan.robot { |bot| base_faces(bot); bot.release_after "15000" } }
    assert_raise(ArgumentError) { StackChan.robot { |bot| base_faces(bot); bot.release_after nil } }
  end

  def test_each_handler_kind_without_a_block_raises
    assert_raise(ArgumentError) { StackChan.robot { |bot| base_faces(bot); bot.on_boot } }
    assert_raise(ArgumentError) { StackChan.robot { |bot| base_faces(bot); bot.on_touch(:back) } }
    assert_raise(ArgumentError) { StackChan.robot { |bot| base_faces(bot); bot.on_frame("X") } }
    assert_raise(ArgumentError) { StackChan.robot { |bot| base_faces(bot); bot.remote(:wave) } }
    assert_raise(ArgumentError) { StackChan.robot { |bot| base_faces(bot); bot.every(100) } }
  end
end
