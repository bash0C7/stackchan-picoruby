class IosAppTest < Picotest::Test
  PATH = "/tmp/_ios_app_test_app.rb"
  DETAIL = "<YR_actual:0,PU_actual:0>"

  def setup
    FakeClock.reset(0)
    src = File.open("#{ENV['STACKCHAN_REPO_ROOT']}/apps/ios/app.rb", "r") { |f| f.read }
    File.open(PATH, "w") { |f| f.write(src.sub("App = ", "IosApp = ")) }
    load PATH
    @radio = FakeRobotRadio.new
    central = StackChan::Controller::Central.new(name_prefix: "StackChan", radio: @radio, log_fn: ->(_line) {})
    @lines = []
    lines = @lines
    @daemon = IosApp.wire(central: central, clock: -> { FakeClock.now }, log: ->(_line) {},
                          out: ->(line) { lines << line })
  end

  def ok(out)
    { status: :ok, out: out, message: nil }
  end

  def audio_writes_after(announce)
    out = []
    seen = false
    @radio.writes.each do |_handle, value|
      out << value if seen
      seen = true if value == announce
    end
    out
  end

  def test_face_takes_the_name_from_the_text
    assert_equal ok("OK face=joy"), @daemon.act("face", "joy")
    assert_equal ["<F:2>\n"], @radio.rx_frames
  end

  def test_face_without_a_name_answers_its_usage_line_and_writes_nothing
    assert_equal ok("face: a face name is required"), @daemon.act("face", "")
    assert_equal [], @radio.rx_frames
  end

  def test_each_face_button_shows_its_face
    assert_equal ok("OK face=neutral"), @daemon.act("neutral", "")
    assert_equal ok("OK face=smile"), @daemon.act("smile", "")
    assert_equal ok("OK face=joy"), @daemon.act("joy", "")
    assert_equal ok("OK face=surprised"), @daemon.act("surprised", "")
    assert_equal ok("OK face=sad"), @daemon.act("sad", "")
    assert_equal ok("OK face=angry"), @daemon.act("angry", "")
    assert_equal ["<F:0>\n", "<F:1>\n", "<F:2>\n", "<F:3>\n", "<F:4>\n", "<F:5>\n"], @radio.rx_frames
  end

  def test_led_defaults_to_solid_on_both_sides
    assert_equal ok("OK led=both/red/solid"), @daemon.act("led", "red")
    assert_equal ["<L:1,R:255,G:0,B:0,S:B,M:s>\n"], @radio.rx_frames
  end

  def test_led_takes_mode_and_side
    assert_equal ok("OK led=left/green/blink"), @daemon.act("led", "green blink left")
    assert_equal ["<L:1,R:0,G:255,B:0,S:R,M:b>\n"], @radio.rx_frames
  end

  def test_led_without_a_color_answers_its_usage_line_and_writes_nothing
    assert_equal ok("led: color [mode] [side] is required"), @daemon.act("led", "")
    assert_equal [], @radio.rx_frames
  end

  def test_head_buttons
    assert_equal ok("OK head=left <YL_actual:40,PU_actual:0>"), @daemon.act("left", "")
    assert_equal ok("OK head=center <YR_actual:0,PU_actual:0>"), @daemon.act("center", "")
    assert_equal ok("OK head=right <YR_actual:40,PU_actual:0>"), @daemon.act("right", "")
    assert_equal ok("OK head=up <YR_actual:40,PU_actual:29>"), @daemon.act("up", "")
    assert_equal ["<YL:40,T:400>\n", "<YL:0,PU:0,T:400>\n", "<YR:40,T:400>\n", "<PU:30,T:400>\n"], @radio.rx_frames
  end

  def test_subtitle_sends_the_whole_text
    assert_equal ok("OK subtitle=やあ ねえ"), @daemon.act("subtitle", "やあ ねえ")
    assert_equal ["<text:やあ ねえ>\n"], @radio.rx_frames
  end

  def test_selftest
    assert_equal ok("OK selftest detail=\"#{DETAIL}\\n\""), @daemon.act("selftest", "")
    assert_equal ["<selftest:run>\n"], @radio.rx_frames
  end

  def test_the_app_holds_the_link_for_ten_seconds
    assert_equal 10_000, IosApp.hold_ms
  end

  def test_actions_from_the_bridge_list_every_button
    IosApp.__send__(:actions, "")
    assert_equal ["connect\tconnect", "status\tstatus", "stop\tstop", "face\tFace", "neutral\tneutral", "smile\tsmile",
                  "joy\tjoy", "surprised\tsurprised", "sad\tsad", "angry\tangry", "led\tLED", "left\tLeft",
                  "center\tCenter", "right\tRight", "up\tUp", "subtitle\tSubtitle", "selftest\tSelftest"], @lines
  end

  def test_a_bridge_call_prints_the_action_line
    IosApp.__send__(:face, "joy")
    assert_equal ["OK face=joy"], @lines
    assert_equal ["<F:2>\n"], @radio.rx_frames
  end

  def test_connect_from_the_bridge_prints_the_line_the_connect_button_waits_for
    IosApp.__send__(:connect, "")
    assert_equal ["Connected; RX value_handle bound"], @lines
  end

  def test_speak_audio_from_the_bridge_takes_the_synthesised_hex
    IosApp.__send__(:speak_audio, "7f00ff")
    assert_equal ["OK speak_audio bytes=3"], @lines
    assert_equal ["<A:3>\n"], @radio.rx_frames
    assert_equal ["\x7f\x00\xff"], audio_writes_after("<A:3>\n")
  end
end
