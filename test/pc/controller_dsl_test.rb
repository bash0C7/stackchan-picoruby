class ControllerDslTest < Picotest::Test
  TICK_MS = 250

  class StubVoice
    def synthesize(_text, _gain = nil, _rate = nil)
      nil
    end

    def respond(_text, _state)
      "hello"
    end
  end

  class DropOnDrbRadio < FakeRobotRadio
    def write_value_of_characteristic_without_response(conn_handle, handle, value)
      if handle == DRX
        drop_link(event: true)
        return false
      end
      super
    end
  end

  def app(hold: 10_000)
    seen = { touch: [], reply: [], every: [] }
    @seen = seen
    StackChan.controller do |c|
      c.hold hold
      c.action(:face, label: "Face") { |s, a| s.face(a[0].to_sym); "OK face=#{a[0]}" }
      c.action(:chatty) { |s, a| s.chat(a[0], speak: false) }
      c.action(:probe) { |s, _a| s.remote(:echo, "x") }
      c.on_touch { |_s, zone| seen[:touch] << zone }
      c.on_reply { |_s, text| seen[:reply] << text }
      c.every(1000) { |_s| seen[:every] << FakeClock.now }
    end
  end

  def wire(controller, radio: nil)
    FakeClock.reset(0)
    @radio = radio || FakeRobotRadio.new
    @central = StackChan::Controller::Central.new(name_prefix: "StackChan", radio: @radio, log_fn: ->(_line) {})
    @logs = []
    @lines = []
    logs = @logs
    lines = @lines
    @daemon = controller.wire(central: @central, voice: StubVoice.new, clock: -> { FakeClock.now },
                              log: ->(line) { logs << line }, out: ->(line) { lines << line })
    controller
  end

  def setup
    @app = wire(app)
  end

  def tick_until(t)
    while FakeClock.now < t
      sleep_ms TICK_MS
      @app.tick
    end
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

  def builder_error(&blk)
    StackChan.controller(&blk)
    nil
  rescue ArgumentError => e
    e.message
  end

  def test_controller_returns_a_controller
    assert_equal StackChan::Controller, app.class
  end

  def test_controller_without_a_block_raises
    assert_raise(ArgumentError, "StackChan.controller needs a block") { StackChan.controller }
  end

  def test_wire_returns_the_daemon
    assert_equal StackChan::Controller::Daemon, @daemon.class
  end

  def test_an_action_writes_its_frames_and_answers_its_block_value
    assert_equal({ status: :ok, out: "OK face=joy", message: nil }, @app.act(:face, ["joy"]))
    assert_equal ["<F:2>\n"], @radio.rx_frames
  end

  def test_an_action_name_given_as_a_string_is_the_same_action
    assert_equal :ok, @app.act("face", ["sad"])[:status]
    assert_equal ["<F:4>\n"], @radio.rx_frames
  end

  def test_actions_lists_the_button_built_ins_then_the_declared_actions_in_order
    assert_equal [[:connect, nil], [:status, nil], [:stop, nil], [:face, "Face"], [:chatty, nil], [:probe, nil]], @app.actions
    assert_equal @app.actions, @daemon.actions
  end

  def test_on_touch_runs_for_a_touch_while_held
    @app.act(:face, ["joy"])
    @radio.touch(1)
    tick_until(FakeClock.now + TICK_MS)
    assert_equal [:right], @seen[:touch]
  end

  def test_on_reply_sees_the_voice_reply
    assert_equal({ status: :ok, out: "hello", message: nil }, @app.act(:chatty, ["hi"]))
    assert_equal ["hello"], @seen[:reply]
  end

  def test_every_runs_while_held
    @app.act(:face, ["joy"])
    t0 = FakeClock.now
    tick_until(t0 + 2_600)
    assert_true @seen[:every].size >= 1
    assert_true @seen[:every].first <= t0 + 1_250
  end

  def test_hold_sets_when_keepalive_stops
    @app = wire(app(hold: 3_000))
    @app.act(:face, ["joy"])
    tick_until(FakeClock.now + 3_000)
    assert_equal "quiet", @daemon.status[:link]
    assert_equal 3_000, @daemon.status[:hold_ms]
    @app = wire(app(hold: 10_000))
    @app.act(:face, ["joy"])
    tick_until(FakeClock.now + 3_000)
    assert_equal "held", @daemon.status[:link]
  end

  def test_an_action_named_like_a_built_in_is_rejected
    StackChan::Controller::BUILTINS.each do |name|
      assert_equal "action: #{name.inspect} is a built-in action", builder_error { |c| c.action(name) { |_s, _a| } }
    end
  end

  def test_an_action_named_like_a_controller_method_is_rejected
    [:tick, :wire, :serve, :act, :actions].each do |name|
      assert_equal "action: #{name.inspect} is already a method of the controller",
                   builder_error { |c| c.action(name) { |_s, _a| } }
    end
  end

  def test_an_action_declared_twice_is_rejected
    assert_equal "action: :face is already declared",
                 builder_error { |c| c.action(:face) { |_s, _a| }; c.action(:face) { |_s, _a| } }
  end

  def test_an_action_name_that_is_not_a_symbol_is_rejected
    assert_equal "action: name must be a Symbol, got \"face\"", builder_error { |c| c.action("face") { |_s, _a| } }
  end

  def test_hold_and_every_need_a_positive_integer
    assert_equal "hold: must be a positive Integer of ms, got 0", builder_error { |c| c.hold 0 }
    assert_equal "hold: must be a positive Integer of ms, got \"10\"", builder_error { |c| c.hold "10" }
    assert_equal "every: period must be a positive Integer of ms, got -1", builder_error { |c| c.every(-1) { |_s| } }
  end

  def test_each_handler_kind_needs_a_block
    assert_equal "action needs a block", builder_error { |c| c.action(:face) }
    assert_equal "on_touch needs a block", builder_error { |c| c.on_touch }
    assert_equal "on_reply needs a block", builder_error { |c| c.on_reply }
    assert_equal "every needs a block", builder_error { |c| c.every(1000) }
  end

  def test_an_undeclared_name_is_unknown_and_touches_nothing
    assert_equal :unknown, @app.act(:nope, [])[:status]
    assert_equal 0, @radio.connect_and_discover_calls
  end

  def test_a_busy_robot_answers_busy
    @radio.advertising = false
    assert_equal({ status: :busy, out: nil, message: StackChan::Controller::Link::BUSY_MESSAGE }, @app.act(:face, ["joy"]))
    assert_equal "busy", @daemon.status[:link]
  end

  def test_a_druby_call_nobody_answers_is_an_error_and_the_next_action_still_runs
    result = @app.act(:probe, [])
    assert_equal :error, result[:status]
    assert_true result[:message].include?("no reply")
    assert_equal :ok, @app.act(:face, ["joy"])[:status]
  end

  def test_a_druby_call_whose_link_drops_is_an_error_and_releases_the_link
    @app = wire(app, radio: DropOnDrbRadio.new)
    result = @app.act(:probe, [])
    assert_equal :error, result[:status]
    assert_equal "released", @daemon.status[:link]
    assert_equal :ok, @app.act(:face, ["joy"])[:status]
    assert_equal 2, @radio.connect_and_discover_calls
  end

  def test_an_action_block_error_is_an_error_result
    broken = wire(StackChan.controller { |c| c.action(:boom) { |_s, _a| raise "boom" } })
    assert_equal({ status: :error, out: nil, message: "boom" }, broken.act(:boom, []))
  end

  def test_send_of_an_action_name_prints_its_line_and_returns_the_result
    result = @app.__send__(:face, "joy")
    assert_equal :ok, result[:status]
    assert_equal ["<F:2>\n"], @radio.rx_frames
    assert_equal ["OK face=joy"], @lines
  end

  def test_send_of_an_action_prints_busy
    @radio.advertising = false
    @app.__send__(:face, "joy")
    assert_equal ["busy: #{StackChan::Controller::Link::BUSY_MESSAGE}"], @lines
  end

  def test_send_of_an_action_prints_error
    @app.__send__(:probe, nil)
    assert_equal 1, @lines.size
    assert_true @lines[0].start_with?("error: ")
  end

  def test_send_prints_a_hash_as_key_value_pairs
    @app.__send__(:status, "")
    assert_true @lines[0].start_with?("ble_connected=false ")
    assert_true @lines[0].include?(" link=released ")
  end

  def test_the_controller_responds_to_action_names_only
    assert_true @app.respond_to?(:face)
    assert_true @app.respond_to?(:speak_audio)
    assert_false @app.respond_to?(:nope)
    assert_raise(NoMethodError) { @app.nope }
  end

  def test_send_of_tick_runs_one_tick
    @app.act(:face, ["joy"])
    @radio.touch(0)
    @app.__send__(:tick, "")
    assert_equal [:back], @seen[:touch]
  end

  def test_speak_audio_takes_hex
    assert_equal "OK speak_audio bytes=2", @app.__send__(:speak_audio, "7f7f")[:out]
    assert_equal ["<A:2>\n"], @radio.rx_frames
    assert_equal ["\x7f\x7f"], audio_writes_after("<A:2>\n")
  end

  def test_speak_audio_takes_raw_bytes
    assert_equal :ok, @app.act(:speak_audio, ["\x01 \xff"])[:status]
    assert_equal ["\x01 \xff"], audio_writes_after("<A:3>\n")
  end

  def test_status_does_not_touch_the_link
    result = @app.act(:status, [])
    assert_equal :ok, result[:status]
    assert_equal "released", result[:out][:link]
    assert_equal 0, @radio.connect_and_discover_calls
  end

  def test_connect_connects_once
    assert_equal({ status: :ok, out: "connected.", message: nil }, @app.act(:connect, []))
    assert_equal 1, @daemon.status[:connects]
    assert_equal [], @radio.rx_frames
  end

  def test_raw_writes_the_frame
    assert_equal "OK raw", @app.act(:raw, ["<F:1>"])[:out]
    assert_equal ["<F:1>\n"], @radio.rx_frames
  end

  def test_calibrate_phases
    assert_equal :ok, @app.act(:calibrate, ["begin"])[:status]
    assert_equal({ yaw_raw: 2048, pitch_raw: 2048 }, @app.act(:calibrate, ["sample", "3"])[:out])
    assert_equal :ok, @app.act(:calibrate, ["end"])[:status]
    assert_equal ["<torque:off>\n", "<read:pos>\n", "<read:pos>\n", "<read:pos>\n", "<torque:on>\n"], @radio.rx_frames
    assert_equal :error, @app.act(:calibrate, ["bogus"])[:status]
  end

  def test_args_positionals_and_options
    a = StackChan::Controller::Args.new(["hi", "--gain", "1.5", "--rate", "200", "--no-speak"])
    assert_equal "hi", a[0]
    assert_equal 1, a.size
    assert_equal 1.5, a.float("gain")
    assert_equal 200, a.int("rate")
    assert_true a.flag?("no-speak")
    assert_false a.flag?("loud")
    assert_nil a.opt("time")
    assert_nil a.int("time")
  end

  def test_args_flag_is_removed_from_positionals
    a = StackChan::Controller::Args.new(["--no-speak", "hi"])
    assert_true a.flag?("no-speak")
    assert_equal "hi", a[0]
    assert_equal 1, a.size
  end

  def test_args_from_a_string_or_nil
    assert_equal ["both", "green", "solid"], [0, 1, 2].map { |i| StackChan::Controller::Args.new("both green solid")[i] }
    assert_equal 0, StackChan::Controller::Args.new(nil).size
    assert_equal 0, StackChan::Controller::Args.new("").size
  end
end
