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

  def test_each_face_button_shows_its_face
    assert_equal ok("OK face=neutral"), @daemon.act("neutral", "")
    assert_equal ok("OK face=smile"), @daemon.act("smile", "")
    assert_equal ok("OK face=joy"), @daemon.act("joy", "")
    assert_equal ok("OK face=surprised"), @daemon.act("surprised", "")
    assert_equal ok("OK face=sad"), @daemon.act("sad", "")
    assert_equal ok("OK face=angry"), @daemon.act("angry", "")
    assert_equal ["<F:0>\n", "<F:1>\n", "<F:2>\n", "<F:3>\n", "<F:4>\n", "<F:5>\n"], @radio.rx_frames
  end

  def test_each_led_button_sends_its_colour_solid_on_both_sides
    frames = { "red" => "R:255,G:0,B:0", "green" => "R:0,G:255,B:0", "blue" => "R:0,G:0,B:255",
               "yellow" => "R:255,G:255,B:0", "cyan" => "R:0,G:255,B:255", "magenta" => "R:255,G:0,B:255",
               "white" => "R:255,G:255,B:255" }
    frames.each do |color, rgb|
      assert_equal ok("OK led=both/#{color}/solid"), @daemon.act("led_#{color}", "")
    end
    assert_equal frames.values.map { |rgb| "<L:1,#{rgb},S:B,M:s>\n" }, @radio.rx_frames
  end

  def test_led_off_button_turns_both_sides_off
    assert_equal ok("OK led=both/off/off"), @daemon.act("led_off", "")
    assert_equal ["<L:1,R:0,G:0,B:0,S:B,M:o>\n"], @radio.rx_frames
  end

  def test_no_button_answers_an_error_to_the_default_speech_sentence
    sentence = "ぼくスタックチャン、かわいいよ"
    IosApp.__send__(:actions, "")
    names = @lines.map { |l| l.split("\t")[0] } - %w[connect status stop]
    @lines.clear
    failing = names.select do |name|
      reply = @daemon.act(name, sentence)
      reply[:status] != :ok || reply[:out].to_s.start_with?("error")
    end
    assert_equal [], failing
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
assert_equal ["connect\tconnect", "status\tstatus", "stop\tstop", "neutral\tneutral", "smile\tsmile",
              "joy\tjoy", "surprised\tsurprised", "sad\tsad", "angry\tangry", "led_red\tLED red",
              "led_green\tLED green", "led_blue\tLED blue", "led_yellow\tLED yellow", "led_cyan\tLED cyan",
              "led_magenta\tLED magenta", "led_white\tLED white", "led_off\tLED off", "left\tLeft",
              "center\tCenter", "right\tRight", "up\tUp", "subtitle\tSubtitle", "selftest\tSelftest"], @lines
  end

  def test_a_bridge_call_prints_the_action_line
    IosApp.__send__(:joy, "")
    assert_equal ["OK face=joy"], @lines
    assert_equal ["<F:2>\n"], @radio.rx_frames
  end

  def test_connect_from_the_bridge_prints_the_line_the_connect_button_waits_for
    IosApp.__send__(:connect, "")
    assert_equal ["Connected; dRuby pair bound"], @lines
  end

  def test_speak_audio_from_the_bridge_takes_the_synthesised_hex
    IosApp.__send__(:speak_audio, "7f00ff")
    assert_equal ["OK speak_audio bytes=3"], @lines
    assert_equal [], @radio.rx_frames
    assert_equal [[0x7f, 0x00, 0xff]], @radio.speaker.played.map(&:bytes)
  end

  def passing_bridge_lines
    central = StackChan::Controller::Central.new(name_prefix: "StackChan", radio: PassingRadio.new, log_fn: ->(_line) {})
    lines = []
    IosApp.wire(central: central, clock: -> { FakeClock.now }, log: ->(_line) {}, out: ->(line) { lines << line })
    lines
  end

  def test_a_declared_action_from_the_bridge_runs_without_a_c_frame_around_the_scheduler
    lines = passing_bridge_lines
    IosApp.__send__(:joy, "")
    assert_equal ["OK face=joy"], lines
  end

  def test_a_built_in_action_from_the_bridge_runs_without_a_c_frame_around_the_scheduler
    lines = passing_bridge_lines
    IosApp.__send__(:raw, "<torque:on>")
    assert_equal ["OK raw"], lines
  end

  def test_every_action_name_answers_respond_to
    [:connect, :status, :stop, :raw, :calibrate, :speak_audio, :joy, :led_red].each do |name|
      assert IosApp.respond_to?(name)
    end
  end
end
