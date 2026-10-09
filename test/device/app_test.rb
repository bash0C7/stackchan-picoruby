class AppTest < Picotest::Test
  class AppTouch
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

  class AppSink
    attr_reader :writes
    def initialize; @writes = []; end
    def write(b); @writes << b; end
  end

  GOLDEN_DIR = File.join(ENV["STACKCHAN_REPO_ROOT"].to_s, "spec", "golden")

  def setup
    @display  = FakeDisplay.new
    @led      = FakeLed.new
    @touch    = AppTouch.new
    @stdout   = AppSink.new
    @wiring = RobotApp.robot.wire(
      display: @display, led: @led, touch: @touch,
      stdout: @stdout
    )
  end

  def dump_of(&draw)
    display = FakeDisplay.new
    draw.call(display)
    FaceGoldenHash.canonical_dump(display.calls)
  end

  def flashes
    @led.calls.select { |c| c.first == :flash_side }.map(&:last)
  end

  def assert_face_drawn(name)
    expected = FaceGoldenHash::FACE_CASES[name]
    assert_equal File.read(File.join(GOLDEN_DIR, "face_#{name}.dump")),
                 FaceGoldenHash.compute_dump(@wiring.dispatcher.current_face)
    assert_equal dump_of { |d| expected.redraw(d) }, FaceGoldenHash.canonical_dump(@display.calls)
  end

  def test_the_app_file_evaluates_to_a_robot
    assert_equal StackChan::Robot, RobotApp.robot.class
  end

  def test_the_app_releases_an_idle_central_after_15_s
    assert_equal 15_000, RobotApp.robot.release_after
  end

  def test_face_index_0_draws_neutral
    @wiring.dispatcher.handle({ "F" => "0" })
    assert_face_drawn(:neutral)
  end

  def test_face_index_1_draws_smile
    @wiring.dispatcher.handle({ "F" => "1" })
    assert_face_drawn(:smile)
  end

  def test_face_index_2_draws_joy
    @wiring.dispatcher.handle({ "F" => "2" })
    assert_face_drawn(:joy)
  end

  def test_face_index_3_draws_surprised
    @wiring.dispatcher.handle({ "F" => "3" })
    assert_face_drawn(:surprised)
  end

  def test_face_index_4_draws_sad
    @wiring.dispatcher.handle({ "F" => "4" })
    assert_face_drawn(:sad)
  end

  def test_face_index_5_draws_angry
    @wiring.dispatcher.handle({ "F" => "5" })
    assert_face_drawn(:angry)
  end

  def test_face_index_6_is_not_defined
    @wiring.dispatcher.handle({ "F" => "6" })
    assert_equal ["?\n"], @stdout.writes
  end

  def test_the_closed_face_matches_its_golden
    assert @wiring.dispatcher.show_face(:closed)
    assert_face_drawn(:closed)
  end

  def test_back_touch_draws_surprised_and_flashes_both_green
    @touch.next_zone = 0
    @wiring.ticker.tick(0)
    assert_face_drawn(:surprised)
    assert_equal [[:both, 0, 60, 0, 300]], flashes
    assert_equal [0], @wiring.remote.touches
  end

  def test_right_touch_draws_angry_and_flashes_right_red
    @touch.next_zone = 1
    @wiring.ticker.tick(0)
    assert_face_drawn(:angry)
    assert_equal [[:right, 60, 0, 0, 300]], flashes
    assert_equal [1], @wiring.remote.touches
  end

  def test_left_touch_draws_sad_and_flashes_left_blue
    @touch.next_zone = 2
    @wiring.ticker.tick(0)
    assert_face_drawn(:sad)
    assert_equal [[:left, 0, 0, 60, 300]], flashes
    assert_equal [2], @wiring.remote.touches
  end

  def test_blink_closes_at_5000_ms_and_reopens_150_ms_later
    neutral = FaceGoldenHash::FACE_CASES[:neutral]
    @wiring.ticker.tick(0)
    @wiring.ticker.tick(4999)
    assert_equal [], @display.calls
    @wiring.ticker.tick(5000)
    assert_equal dump_of { |d| neutral.redraw_eyes_closed(d) }, FaceGoldenHash.canonical_dump(@display.calls)
    @display.calls.clear
    @wiring.ticker.tick(5149)
    assert_equal [], @display.calls
    @wiring.ticker.tick(5150)
    assert_equal dump_of { |d| neutral.redraw_eyes_open(d) }, FaceGoldenHash.canonical_dump(@display.calls)
  end
end
