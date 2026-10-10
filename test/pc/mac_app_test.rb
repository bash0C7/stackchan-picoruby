class MacAppTest < Picotest::Test
  class StubVoice
    def synthesize(text, _gain = nil, _rate = nil)
      "\x7f" * (text.to_s.length * 80)
    end

    def respond(prompt, _state)
      "stub返答:#{prompt}"[0, 19]
    end
  end

  def setup
    FakeClock.reset(0)
    @radio = FakeRobotRadio.new
    central = StackChan::Controller::Central.new(name_prefix: "StackChan", radio: @radio, log_fn: ->(_line) {})
    @daemon = App.wire(central: central, voice: StubVoice.new, clock: -> { FakeClock.now }, log: ->(_line) {},
                       out: ->(_line) {})
  end

  def act(*argv)
    verb = argv.shift
    @daemon.act(verb, argv)
  end

  def ok(out)
    { status: :ok, out: out, message: nil }
  end

  def test_remote_servo_right_after_a_servo_action_answers_the_ack_and_the_detail
    act("servo", "--yaw-left", "50", "--pitch-up", "30", "--time", "500")
    result = @daemon.remote("servo", [{ "YL" => "40", "PU" => "20", "T" => "500" }])
    assert_equal :ok, result[:status]
    assert_equal ".\n", result[:out][0]
    assert result[:out][1].start_with?("<YL_actual:")
  end
  
  def test_a_remote_call_the_robot_does_not_expose_answers_an_error_result
    result = @daemon.remote("reboot", [])
    assert_equal :error, result[:status]
    assert result[:message].include?("not exposed")
  end
  
  def test_face
    assert_equal ok("OK face=joy"), act("face", "joy")
    assert_equal ["<F:2>\n"], @radio.rx_frames
  end

  def test_led
    assert_equal ok("OK led=both/green/solid"), act("led", "both", "green", "solid")
    assert_equal ["<L:1,R:0,G:255,B:0,S:B,M:s>\n"], @radio.rx_frames
  end

  def test_led_without_a_mode_answers_its_usage_line_and_writes_nothing
    assert_equal ok("led: side color mode required"), act("led", "both")
    assert_equal [], @radio.rx_frames
  end

  def test_servo
    assert_equal ok("servo detail=\"<YL_actual:50,PU_actual:29>\\n\""),
                 act("servo", "--yaw-left", "50", "--pitch-up", "30", "--time", "500")
    assert_equal ["<YL:50,PU:30,T:500>\n"], @radio.rx_frames
  end

  def test_torque
    assert_equal ok("OK torque=on"), act("torque", "on")
    assert_equal ok("OK torque=off"), act("torque", "off")
    assert_equal ["<torque:on>\n", "<torque:off>\n"], @radio.rx_frames
  end

  def test_selftest
    assert_equal ok("OK selftest detail=\"<YR_actual:0,PU_actual:0>\\n\""), act("selftest")
    assert_equal ["<selftest:run>\n"], @radio.rx_frames
  end

  def test_say
    assert_equal ok("OK say bytes=400"), act("say", "こんにちは")
    assert_equal ["<text:こんにちは>\n", "<A:400>\n"], @radio.rx_frames
  end

  def test_chat_shows_the_reply_with_a_smile_then_says_it
    assert_equal ok("reply=stub返答:こんにちは"), act("chat", "こんにちは")
    assert_equal ["<F:1,text:stub返答:こんにちは>\n", "<text:stub返答:こんにちは>\n", "<A:960>\n"], @radio.rx_frames
  end

  def test_chat_no_speak_shows_the_reply_only
    assert_equal ok("reply=stub返答:こんにちは"), act("chat", "--no-speak", "こんにちは")
    assert_equal ["<F:1,text:stub返答:こんにちは>\n"], @radio.rx_frames
  end

  def test_demo_of_one_second_has_no_step
    assert_equal ok(["[demo] start", "[demo] done"]), act("demo", "--duration", "1")
    assert_equal ["<L:1,R:255,G:0,B:0,S:R,M:b>\n", "<L:1,R:0,G:0,B:255,S:L,M:p>\n", "<text:ぼくスタックチャン！>\n",
                  "<A:800>\n", "<F:0>\n", "<L:1,R:0,G:0,B:0,S:B,M:o>\n", "<YL:0,PU:0,T:800>\n",
                  "<text:タッチしてみて>\n", "<A:560>\n"], @radio.rx_frames
  end

  def test_demo_of_three_seconds_has_two_steps
    assert_equal ok(["[demo] start", "[demo] done"]), act("demo", "--duration", "3")
    assert_equal ["<L:1,R:255,G:0,B:0,S:R,M:b>\n", "<L:1,R:0,G:0,B:255,S:L,M:p>\n", "<text:ぼくスタックチャン！>\n",
                  "<A:800>\n",
                  "<F:2>\n", "<L:1,R:255,G:0,B:0,S:R,M:b>\n", "<L:1,R:0,G:0,B:255,S:L,M:p>\n", "<YL:60,PU:30,T:800>\n",
                  "<F:1>\n", "<L:1,R:255,G:255,B:0,S:R,M:p>\n", "<L:1,R:255,G:0,B:255,S:L,M:s>\n", "<YR:60,PU:30,T:800>\n",
                  "<F:0>\n", "<L:1,R:0,G:0,B:0,S:B,M:o>\n", "<YL:0,PU:0,T:800>\n",
                  "<text:タッチしてみて>\n", "<A:560>\n"], @radio.rx_frames
  end

  def test_the_app_holds_the_link_for_ten_seconds
    assert_equal 10_000, App.hold_ms
  end

  def test_the_app_declares_face_led_servo_torque_selftest_say_chat_and_demo
    names = App.actions.map { |pair| pair[0] }
    assert_equal [:connect, :status, :stop, :face, :led, :servo, :torque, :selftest, :say, :chat, :demo], names
  end
end
