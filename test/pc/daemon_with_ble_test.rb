class DaemonWithBleTest < Picotest::Test
  class InterleavingBle
    attr_reader :log

    def initialize(raise_on: nil)
      @log = []
      @raise_on = raise_on
    end

    def send
      b = Stackchan::BLE::SendBuilder.new
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
        raise Stackchan::BLE::DeviceError, "rejected #{frame}"
      end
      @log << [:end, frame]
      self
    end
  end

  def run_two_face_calls(daemon, first, second)
    t1 = Task.new(name: "first") do
      begin
        daemon.face(first)
      rescue Stackchan::BLE::DeviceError
      end
    end
    t2 = Task.new(name: "second") { daemon.face(second) }
    t1.join
    t2.join
  end

  def test_a_second_caller_starts_only_after_the_first_body_ends
    ble = InterleavingBle.new
    run_two_face_calls(Stackchan::Daemon.new(ble: ble), "joy", "sad")
    assert_equal [[:start, "<F:2>\n"], [:end, "<F:2>\n"], [:start, "<F:4>\n"], [:end, "<F:4>\n"]], ble.log
  end

  def test_a_second_caller_starts_only_after_the_first_body_raises
    ble = InterleavingBle.new(raise_on: "<F:2>\n")
    run_two_face_calls(Stackchan::Daemon.new(ble: ble), "joy", "sad")
    assert_equal [[:start, "<F:2>\n"], [:raise, "<F:2>\n"], [:start, "<F:4>\n"], [:end, "<F:4>\n"]], ble.log
  end
end
