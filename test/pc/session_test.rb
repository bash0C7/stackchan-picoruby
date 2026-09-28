class SessionTest < Picotest::Test
  TICK_MS = 250
  AUDIO = "\x7f" * 400

  class StubVoice
    attr_accessor :token, :during_respond, :during_synthesize, :audio
    attr_reader :respond_calls, :token_sizes

    def initialize(reply: "hello", audio: AUDIO)
      @reply = reply
      @audio = audio
      @respond_calls = 0
      @token_sizes = []
      @token = nil
      @during_respond = nil
      @during_synthesize = nil
    end

    def synthesize(_text, _gain = nil, _rate = nil)
      @token_sizes << [:synthesize, @token.size]
      hook = @during_synthesize
      @during_synthesize = nil
      hook.call if hook
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
                                                clock: -> { FakeClock.now }, log: log, actions: verbs)
    voice.token = token if voice
  end

  def verbs
    StackChan.controller do |c|
      c.action(:face) { |s, a| s.face(a[0].to_sym); "OK face=#{a[0]}" }
      c.action(:say) { |s, a| s.say(a[0]) }
      c.action(:chat, flags: ["no-speak"]) { |s, a| s.chat(a[0], speak: !a.flag?("no-speak")) }
    end.declared
  end

  def setup
    build
  end

  def face(name)
    @daemon.act(:face, [name])
  end

  def say(text)
    @daemon.act(:say, [text])
  end

  def chat(text, speak:)
    @daemon.act(:chat, speak ? [text] : ["--no-speak", text])
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

  def test_a_touch_while_held_reaches_on_touch_and_poll_touch_within_one_tick
    seen = []
    @daemon.on_touch { |_s, zone| seen << zone }
    face("joy")
    @radio.touch(1)
    tick
    assert_equal [:right], seen
    assert_equal({ zone: 1, name: :right }, @daemon.poll_touch)
  end

  def test_a_touch_drained_by_an_action_is_delivered_after_it
    seen = []
    @daemon.on_touch { |_s, zone| seen << [zone, @radio.rx_frames.size] }
    face("joy")
    @radio.touch(2)
    face("sad")
    assert_equal [[:left, 2]], seen
  end

  def test_a_touch_handler_that_sends_a_face_writes_it_without_deadlock
    @daemon.on_touch { |s, _zone| s.face(:joy) }
    face("neutral")
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
    face("neutral")
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
      face("sad")
    end
    face("neutral")
    @radio.touch(0)
    tick
    assert_equal [:back, :right], seen
    assert_equal 1, deepest
  end

  def test_on_reply_sees_the_reply_before_say_streams
    seen = []
    @daemon.on_reply { |_s, text| seen << [text, @radio.rx_frames.dup] }
    face("neutral")
    assert_equal "hello", chat("hi", speak: true)[:out]
    assert_equal [["hello", ["<F:0>\n"]]], seen
    assert_equal ["<F:0>\n", "<text:hello>\n", "<A:400>\n"], @radio.rx_frames
  end

  def test_chat_without_on_reply_sends_no_text_frame
    face("neutral")
    assert_equal "hello", chat("hi", speak: false)[:out]
    assert_equal ["<F:0>\n"], @radio.rx_frames
  end

  def test_respond_runs_once_with_the_token_handed_back
    chat("hi", speak: false)
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
    face("neutral")
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
    face("neutral")
    tick_until(FakeClock.now + 10_000)
    assert_equal :quiet, @link.state
    assert_equal({ released: true }, @daemon.poll_touch)
    assert_equal 1, @radio.connect_and_discover_calls
  end

  def test_poll_touch_while_held_keeps_the_hold
    face("neutral")
    t0 = FakeClock.now
    tick_until(t0 + 9_000)
    assert_nil @daemon.poll_touch
    tick_until(t0 + 15_000)
    assert_equal :held, @link.state
  end

  def test_say_announces_waits_then_paces_180_byte_chunks_until_done
    face("neutral")
    FakeClock.sleeps.clear
    assert_equal "OK say bytes=400", say("hello")[:out]
    assert_equal [180, 180, 40], audio_writes_after("<A:400>\n")
    assert_equal [1500, 20, 20, 20], FakeClock.sleeps
    assert_equal [[:synthesize, 1]], @voice.token_sizes
  end

  def test_a_handler_whose_link_is_replaced_while_it_waits_for_the_voice_stops_writing
    runs = 0
    @daemon.every(1000) do |s|
      runs += 1
      if runs == 1
        s.face(:sad)
        s.say("x")
      end
    end
    @voice.during_synthesize = lambda do
      @radio.drop_link(event: true)
      face("joy")
    end
    face("neutral")
    t0 = FakeClock.now
    tick_until(t0 + 1_500)
    assert_equal 1, runs
    assert_equal ["<F:0>\n", "<F:4>\n", "<F:2>\n"], @radio.rx_frames
    assert_equal [], @radio.writes_after_drop
    assert_equal 2, @radio.connect_and_discover_calls
    assert_true @logs.any? { |l| l.start_with?("every StackChan::Controller::LinkChanged") }
  end

  def test_a_chat_whose_link_is_lost_while_the_voice_thinks_is_an_error_and_stays_released
    face("neutral")
    @voice.during_respond = lambda do
      @radio.drop_link(event: true)
      tick
    end
    assert_equal({ status: :error, out: nil, message: "link changed while the token was handed back" }, chat("hi", speak: false))
    assert_equal :released, @link.state
    assert_equal 1, token.size
  end

  def test_ticks_while_the_voice_thinks_keep_the_link_alive_and_hold_back_handlers
    seen = []
    runs = 0
    @daemon.on_touch { |_s, zone| seen << zone }
    @daemon.every(1000) { |_s| runs += 1 }
    face("neutral")
    t0 = FakeClock.now
    during = nil
    @voice.during_respond = lambda do
      @radio.touch(1)
      tick_until(t0 + 20_000)
      during = [seen.dup, runs, @link.state, @radio.rx_frames.select { |f| f == "<read:pos>\n" }.size]
    end
    chat("hi", speak: false)
    assert_equal [[], 0, :held, 2], during
    assert_equal [:right], seen
  end

  def test_a_loss_clears_touches_nobody_polled
    face("neutral")
    @radio.touch(1)
    tick
    @radio.drop_link(event: true)
    tick
    assert_equal :released, @link.state
    face("joy")
    assert_nil @daemon.poll_touch
  end

  def test_touches_nobody_polls_are_capped
    face("neutral")
    i = 0
    while i < 100
      @radio.touch(i % 3)
      i += 1
    end
    tick
    polled = 0
    polled += 1 while @daemon.poll_touch
    assert_equal StackChan::Controller::Daemon::LISTEN_CAP, polled
  end

  def test_a_touch_handler_raising_a_script_error_still_hands_back_the_token
    @daemon.on_touch { |_s, _zone| raise NotImplementedError, "nope" }
    face("neutral")
    @radio.touch(0)
    assert_raise(NotImplementedError) { face("joy") }
    assert_equal 1, token.size
    assert_equal "OK face=sad", face("sad")[:out]
  end

  def test_say_without_a_voice_is_an_error
    build(voice: nil)
    assert_equal :error, say("hello")[:status]
    assert_equal 1, token.size
  end
end
