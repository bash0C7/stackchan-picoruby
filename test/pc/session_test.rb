class SessionTest < Picotest::Test
  TICK_MS = 250
  AUDIO = "\x7f" * 400

  class StubVoice
    attr_accessor :token, :during_respond, :audio
    attr_reader :respond_calls, :token_sizes

    def initialize(reply: "hello", audio: AUDIO)
      @reply = reply
      @audio = audio
      @respond_calls = 0
      @token_sizes = []
      @token = nil
      @during_respond = nil
    end

    def synthesize(_text, _gain = nil, _rate = nil)
      @token_sizes << [:synthesize, @token.size]
      @audio
    end

    def respond(_text, _state)
      @respond_calls += 1
      @token_sizes << [:respond, @token.size]
      hook = @during_respond
      hook.call if hook
      @reply
    end
  end

  def build(hold: 10_000, voice: StubVoice.new)
    FakeClock.reset(0)
    @logs = []
    log = ->(line) { @logs << line }
    @radio = FakeRobotRadio.new
    @central = StackChan::Controller::Central.new(name_prefix: "StackChan", radio: @radio, log_fn: ->(line) {})
    @link = StackChan::Controller::Link.new(central: @central, clock: -> { FakeClock.now }, hold: hold, log: log)
    @voice = voice
    @daemon = StackChan::Controller::Daemon.new(link: @link, central: @central, voice: voice, sidecar_uri: nil,
                                                clock: -> { FakeClock.now }, log: log)
    voice.token = token if voice
  end

  def setup
    build
  end

  def token
    @daemon.instance_variable_get(:@token)
  end

  def tick
    sleep_ms TICK_MS
    @daemon.tick
  end

  def tick_until(t)
    tick while FakeClock.now < t
  end

  def audio_writes_after(announce)
    sizes = []
    seen = false
    @radio.writes.each do |_handle, value|
      sizes << value.bytesize if seen
      seen = true if value == announce
    end
    sizes
  end

  def test_each_daemon_verb_writes_the_same_frame
    @daemon.face("joy")
    @daemon.led({ side: :left, color: :red, mode: :blink })
    @daemon.servo({ yaw_left: 50, pitch_up: 30, time_ms: 500 })
    @daemon.torque(true)
    @daemon.selftest
    @daemon.raw_send("<read:pos>")
    @daemon.say("hi")
    assert_equal ["<F:2>\n", "<L:1,R:255,G:0,B:0,S:R,M:b>\n", "<YL:50,PU:30,T:500>\n", "<torque:on>\n",
                  "<selftest:run>\n", "<read:pos>\n", "<text:hi>\n", "<A:400>\n"], @radio.rx_frames
  end

  def test_each_daemon_verb_answers_the_same_line
    assert_equal "OK face=joy", @daemon.face("joy")
    assert_equal "OK led=left/red/blink", @daemon.led({ side: :left, color: :red, mode: :blink })
    assert_equal "<YL_actual:0,PU_actual:0>\n", @daemon.servo({ yaw_left: 50 })
    assert_equal "OK torque=off", @daemon.torque(false)
    assert_equal "OK selftest", @daemon.selftest
    assert_equal "OK raw", @daemon.raw_send("<F:0>")
    assert_equal "OK say bytes=400", @daemon.say("hi")
    assert_equal({ yaw_raw: 2048, pitch_raw: 2048 }, @daemon.sample_pose(3))
  end

  def test_a_touch_while_held_reaches_on_touch_and_poll_touch_within_one_tick
    seen = []
    @daemon.on_touch { |_s, zone| seen << zone }
    @daemon.face("joy")
    @radio.touch(1)
    tick
    assert_equal [:right], seen
    assert_equal({ zone: 1, name: :right }, @daemon.poll_touch)
  end

  def test_a_touch_drained_by_an_action_is_delivered_after_it
    seen = []
    @daemon.on_touch { |_s, zone| seen << [zone, @radio.rx_frames.size] }
    @daemon.face("joy")
    @radio.touch(2)
    @daemon.face("sad")
    assert_equal [[:left, 2]], seen
  end

  def test_a_touch_handler_that_sends_a_face_writes_it_without_deadlock
    @daemon.on_touch { |s, _zone| s.face(:joy) }
    @daemon.face("neutral")
    @radio.touch(0)
    tick
    assert_equal ["<F:0>\n", "<F:2>\n"], @radio.rx_frames
    assert_equal 1, token.size
  end

  def test_a_raising_on_touch_handler_is_followed_by_one_more_tick_that_still_delivers_the_next_touch
    calls = 0
    seen = []
    @daemon.on_touch do |_s, zone|
      calls += 1
      raise "boom" if calls == 1
      seen << zone
    end
    @daemon.face("neutral")
    @radio.touch(0)
    tick
    @radio.touch(2)
    tick
    assert_equal [:left], seen
    assert_true @logs.include?("on_touch RuntimeError: boom")
    assert_equal 1, token.size
  end

  def test_a_touch_handler_is_never_entered_again_while_it_runs
    depth = 0
    deepest = 0
    seen = []
    @daemon.on_touch do |s, zone|
      depth += 1
      deepest = depth if depth > deepest
      seen << zone
      s.chat("hi", speak: false) if zone == :back
      depth -= 1
    end
    @voice.during_respond = lambda do
      @radio.touch(1)
      @daemon.face("sad")
    end
    @daemon.face("neutral")
    @radio.touch(0)
    tick
    assert_equal [:back, :right], seen
    assert_equal 1, deepest
  end

  def test_on_reply_sees_the_reply_before_say_streams
    seen = []
    @daemon.on_reply { |_s, text| seen << [text, @radio.rx_frames.dup] }
    @daemon.face("neutral")
    assert_equal "hello", @daemon.chat("hi", { speak: true })
    assert_equal [["hello", ["<F:0>\n"]]], seen
    assert_equal ["<F:0>\n", "<text:hello>\n", "<A:400>\n"], @radio.rx_frames
  end

  def test_chat_without_on_reply_sends_no_text_frame
    @daemon.face("neutral")
    assert_equal "hello", @daemon.chat("hi", { speak: false })
    assert_equal ["<F:0>\n"], @radio.rx_frames
  end

  def test_respond_runs_once_with_the_token_handed_back
    @daemon.chat("hi", { speak: false })
    assert_equal 1, @voice.respond_calls
    assert_equal [[:respond, 1]], @voice.token_sizes
    assert_equal 1, token.size
  end

  def test_every_runs_at_one_second_steps_only_while_held
    runs = []
    @daemon.every(1000) do |s|
      runs << FakeClock.now
      s.face(:joy)
    end
    tick_until(5_000)
    assert_equal [], runs
    @daemon.face("neutral")
    t0 = FakeClock.now
    tick_until(t0 + 30_000)
    assert_equal :quiet, @link.state
    assert_true runs.size >= 8
    i = 1
    while i < runs.size
      assert_equal 1000, runs[i] - runs[i - 1]
      i += 1
    end
    assert_true runs.last < t0 + 10_000
    assert_equal 1, @radio.connect_and_discover_calls
  end

  def test_poll_touch_while_quiet_is_released_and_does_not_connect
    assert_equal({ released: true }, @daemon.poll_touch)
    @daemon.face("neutral")
    tick_until(FakeClock.now + 10_000)
    assert_equal :quiet, @link.state
    assert_equal({ released: true }, @daemon.poll_touch)
    assert_equal 1, @radio.connect_and_discover_calls
  end

  def test_poll_touch_while_held_keeps_the_hold
    @daemon.face("neutral")
    t0 = FakeClock.now
    tick_until(t0 + 9_000)
    assert_nil @daemon.poll_touch
    tick_until(t0 + 15_000)
    assert_equal :held, @link.state
  end

  def test_say_announces_waits_then_paces_180_byte_chunks_until_done
    @daemon.face("neutral")
    FakeClock.sleeps.clear
    assert_equal "OK say bytes=400", @daemon.say("hello")
    assert_equal [180, 180, 40], audio_writes_after("<A:400>\n")
    assert_equal [1500, 20, 20, 20], FakeClock.sleeps
    assert_equal [[:synthesize, 1]], @voice.token_sizes
  end

  def test_say_without_a_voice_raises_argument_error
    build(voice: nil)
    assert_raise(ArgumentError) { @daemon.say("hello") }
    assert_equal 1, token.size
  end
end
