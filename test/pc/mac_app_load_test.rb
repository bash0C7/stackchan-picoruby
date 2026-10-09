class MacAppLoadTest < Picotest::Test
  PATH = "/tmp/_mac_app_load_test_app.rb"

  def setup
    FakeClock.reset(0)
    src = File.open("#{ENV['STACKCHAN_REPO_ROOT']}/apps/mac/app.rb", "r") { |f| f.read }
    File.open(PATH, "w") { |f| f.write(src.sub("App = ", "LoadedMacApp = ")) }
    load PATH
    @radio = FakeRobotRadio.new
    central = StackChan::Controller::Central.new(name_prefix: "StackChan", radio: @radio, log_fn: ->(_line) {})
    @daemon = LoadedMacApp.wire(central: central, clock: -> { FakeClock.now }, log: ->(_line) {}, out: ->(_line) {})
  end

  def test_an_action_of_a_loaded_app_runs_from_another_task_after_load_returned
    result = nil
    daemon = @daemon
    Task.new(name: "drb") { result = daemon.act("face", ["joy"]) }.join
    assert_equal({ status: :ok, out: "OK face=joy", message: nil }, result)
    assert_equal ["<F:2>\n"], @radio.rx_frames
  end
end
