class DaemonWithBleTest < Picotest::Test
  class ScriptedCentral
    attr_accessor :on_unsolicited
    attr_reader :log

    def initialize
      @log = []
      @connected = false
    end

    def connect
      @connected = true
      self
    end

    def connected?
      @connected
    end

    def lost?
      false
    end

    def drain
      @log << [:drain]
    end

    def reset_link
      @connected = false
    end

    def keepalive
      self
    end
  end

  class InterleavingBle < ScriptedCentral
    def initialize(raise_on: nil)
      super()
      @raise_on = raise_on
    end

    def send
      b = StackChan::Controller::SendBuilder.new
      yield b
      frame = b.to_frames[0]
      @log << [:start, frame]
      i = 0
      while i < 5
        Task.pass
        i += 1
      end
      if frame == @raise_on
        @log << [:raise, frame]
        raise StackChan::Controller::DeviceError, "rejected #{frame}"
      end
      @log << [:end, frame]
      self
    end
  end

  class HeldBle < ScriptedCentral
    attr_accessor :release

    def initialize
      super
      @release = false
    end

    def send
      yield StackChan::Controller::SendBuilder.new
      Task.pass until @release
      self
    end
  end

  class FailingDrainBle < ScriptedCentral
    def initialize
      super
      @failures = 1
    end

    def drain
      if @failures > 0
        @failures -= 1
        raise "boom"
      end
      super
    end
  end

  FACE = StackChan.controller { |c| c.action(:face) { |s, a| s.face(a[0].to_sym); "OK face=#{a[0]}" } }.declared

  def build_daemon(central)
    @logs = []
    log = ->(line) { @logs << line }
    link = StackChan::Controller::Link.new(central: central, clock: -> { FakeClock.now }, log: log)
    StackChan::Controller::Daemon.new(link: link, central: central, log: log, actions: FACE)
  end

  def run_two_face_calls(daemon, first, second)
    t1 = Task.new(name: "first") do
      daemon.act(:face, [first])
    end
    t2 = Task.new(name: "second") { daemon.act(:face, [second]) }
    t1.join
    t2.join
  end

  def setup
    FakeClock.reset(0)
  end

  def test_a_second_caller_starts_only_after_the_first_body_ends
    ble = InterleavingBle.new
    run_two_face_calls(build_daemon(ble), "joy", "sad")
    assert_equal [[:start, "<F:2>\n"], [:end, "<F:2>\n"], [:drain], [:start, "<F:4>\n"], [:end, "<F:4>\n"]], ble.log
  end

  def test_a_second_caller_is_parked_on_the_token_while_the_first_holds_it
    ble = HeldBle.new
    daemon = build_daemon(ble)
    t1 = Task.new(name: "first") { daemon.act(:face, ["joy"]) }
    t2 = Task.new(name: "second") { daemon.act(:face, ["sad"]) }
    i = 0
    while i < 10
      Task.pass
      i += 1
    end
    waiting = daemon.instance_variable_get(:@token).num_waiting
    ble.release = true
    t1.join
    t2.join
    assert_equal 1, waiting
  end

  def test_a_second_caller_starts_only_after_the_first_body_raises
    ble = InterleavingBle.new(raise_on: "<F:2>\n")
    run_two_face_calls(build_daemon(ble), "joy", "sad")
    assert_equal [[:start, "<F:2>\n"], [:raise, "<F:2>\n"], [:drain], [:start, "<F:4>\n"], [:end, "<F:4>\n"]], ble.log
  end

  def test_a_tick_waits_for_the_action_that_holds_the_token
    ble = InterleavingBle.new
    daemon = build_daemon(ble)
    daemon.act(:face, ["neutral"])
    ble.log.clear
    t1 = Task.new(name: "action") { daemon.act(:face, ["joy"]) }
    t2 = Task.new(name: "tick") { daemon.tick }
    t1.join
    t2.join
    assert_equal [[:drain], [:start, "<F:2>\n"], [:end, "<F:2>\n"], [:drain]], ble.log
  end

  def test_a_raising_tick_is_logged_and_the_next_tick_still_runs
    ble = FailingDrainBle.new
    daemon = build_daemon(ble)
    daemon.instance_variable_get(:@link).act {}
    daemon.tick
    daemon.tick
    assert_equal [[:drain]], ble.log
    assert_true @logs.include?("tick RuntimeError: boom")
    assert_equal 1, daemon.instance_variable_get(:@token).size
  end

  def test_status_reports_the_link_next_to_ble_connected
    daemon = build_daemon(InterleavingBle.new)
    daemon.act(:face, ["joy"])
    status = daemon.status
    assert_equal "held", status[:link]
    assert_true status[:ble_connected]
    assert_equal 1, status[:connects]
  end
end
