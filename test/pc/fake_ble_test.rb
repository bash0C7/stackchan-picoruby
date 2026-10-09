class FakeBleTest < Picotest::Test
  def setup
    FakeClock.reset(0)
    @daemon = App.wire(central: FakeBleClient.new, clock: -> { FakeClock.now }, log: ->(_line) {}, out: ->(_line) {})
  end

  def test_an_action_connects_and_answers
    assert_equal({ status: :ok, out: "OK face=joy", message: nil }, @daemon.act("face", ["joy"]))
    assert_equal "held", @daemon.status[:link]
    assert_equal 1, @daemon.status[:connects]
  end

  def test_servo_answers_a_detail
    assert_equal "servo detail=\"<YL_actual:0,PU_actual:0>\\n\"", @daemon.act("servo", ["--yaw-left", "10"])[:out]
  end

  def test_remote_answers_lines
    assert_equal ["<face:fake>\n"], @daemon.remote("face", ["joy"])
  end

  def test_ticks_keep_the_link_then_go_quiet_after_the_hold
    @daemon.act("face", ["joy"])
    while FakeClock.now < 12_000
      sleep_ms 250
      @daemon.tick
    end
    assert_equal "quiet", @daemon.status[:link]
  end
end
