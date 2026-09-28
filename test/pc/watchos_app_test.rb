class WatchosAppTest < Picotest::Test
  PATH = "/tmp/_watchos_app_test_app.rb"

  def setup
    FakeClock.reset(0)
    src = File.open("#{ENV['STACKCHAN_REPO_ROOT']}/apps/watchos/app.rb", "r") { |f| f.read }
    File.open(PATH, "w") { |f| f.write(src.sub("App = ", "WatchosApp = ")) }
    load PATH
    @radio = FakeRobotRadio.new
    central = StackChan::Controller::Central.new(name_prefix: "StackChan", radio: @radio, log_fn: ->(_line) {})
    @lines = []
    lines = @lines
    @daemon = WatchosApp.wire(central: central, clock: -> { FakeClock.now }, log: ->(_line) {},
                              out: ->(line) { lines << line })
  end

  def ok(out)
    { status: :ok, out: out, message: nil }
  end

  def test_face_without_a_name_toggles_joy_and_smile
    assert_equal ok("OK face=joy"), @daemon.act("face", "")
    assert_equal ok("OK face=smile"), @daemon.act("face", "")
    assert_equal ok("OK face=joy"), @daemon.act("face", "")
    assert_equal ["<F:2>\n", "<F:1>\n", "<F:2>\n"], @radio.rx_frames
  end

  def test_face_with_a_name_shows_it_and_the_toggle_goes_on_from_it
    assert_equal ok("OK face=smile"), @daemon.act("face", "smile")
    assert_equal ok("OK face=joy"), @daemon.act("face", "")
    assert_equal ["<F:1>\n", "<F:2>\n"], @radio.rx_frames
  end

  def test_led_show_blinks_six_colours_then_goes_dark
    assert_equal ok("OK led_show"), @daemon.act("led_show", "")
    assert_equal ["<L:1,R:255,G:0,B:0,S:B,M:b>\n", "<L:1,R:0,G:255,B:0,S:B,M:b>\n", "<L:1,R:0,G:0,B:255,S:B,M:b>\n",
                  "<L:1,R:255,G:255,B:0,S:B,M:b>\n", "<L:1,R:0,G:255,B:255,S:B,M:b>\n", "<L:1,R:255,G:0,B:255,S:B,M:b>\n",
                  "<L:1,R:0,G:0,B:0,S:B,M:o>\n"], @radio.rx_frames
  end

  def test_head_sweep_goes_left_right_up_and_back
    assert_equal ok("OK head_sweep"), @daemon.act("head_sweep", "")
    assert_equal ["<YL:60,T:500>\n", "<YR:60,T:500>\n", "<PU:40,T:500>\n", "<YL:0,PU:0,T:400>\n"], @radio.rx_frames
  end

  def test_the_app_holds_the_link_for_ten_seconds
    assert_equal 10_000, WatchosApp.hold_ms
  end

  def test_actions_from_the_bridge_list_every_button
    WatchosApp.__send__(:actions, "")
    assert_equal ["connect\tconnect", "status\tstatus", "stop\tstop", "face\t顔をかえる", "led_show\tLEDを光らせる",
                  "head_sweep\tぐるっと"], @lines
  end

  def test_a_bridge_call_prints_the_action_line
    WatchosApp.__send__(:face, "smile")
    assert_equal ["OK face=smile"], @lines
    assert_equal ["<F:1>\n"], @radio.rx_frames
  end

  def test_speak_audio_from_the_bridge_takes_hex
    WatchosApp.__send__(:speak_audio, "7f7f")
    assert_equal ["OK speak_audio bytes=2"], @lines
    assert_equal ["<A:2>\n"], @radio.rx_frames
  end
end
