require 'test/unit'
require 'yaml'
require 'json'
require_relative '../acceptance/runner'
require_relative '../acceptance/ops'

class AcceptanceTest < Test::Unit::TestCase
  ROOT = "/repo"
  LOCK = YAML.safe_load(File.read(File.expand_path("../acceptance/lock.yml", __dir__)))
  FW = LOCK["firmware"]
  ROOT_SHA = "a" * 40
  BUNDLED = %w[mrbgems/picoruby-stackchan-robot mrbgems/picoruby-drb-ble].freeze

  # A machine made of git HEADs: every directory is a checkout at some sha.
  # rake / cli / prompt are scripted; every call is recorded in order.
  class FakeOps
    attr_reader :calls, :heads, :dirty, :submodules, :files, :robot, :exists, :trees
    attr_accessor :boot_log, :cli_out, :answers, :on_rake, :fail_rake, :tty, :on_now, :app_out, :rake_out

    def initialize
      @calls = []
      @heads = {}
      @dirty = {}
      @trees = {}
      @exists = {}
      @answers = []
      @cli_out = {}
      @boot_log = {}
      @on_rake = {}
      @fail_rake = {}
      @app_out = {}
      @rake_out = {}
      @submodules = {}
      @files = {}
      @tty = true
      @clock = 0.0
      @robot = { holder: :a, a_link: "held", connects: 1 }
    end

    def exist?(path) = @exists[path] || @heads.key?(path)

    def read(path) = @boot_log[path] || @files[path]

    def tty? = @tty

    def sleep(seconds)
      @calls << [:sleep, seconds]
      @clock += seconds
      return if seconds < 25
      @robot[:a_link] = "released" if @robot[:a_link] == "held"
      @robot[:holder] = nil
    end

    def notice(text) = @calls << [:notice, text]

    def now
      @calls << [:now]
      @clock += @on_now.call(@calls).to_f if @on_now
      @clock
    end

    def status_line
      r = @robot
      "link=#{r[:a_link]} connects=#{r[:connects]} releases=0 last_connect_ms=1200 hold_ms=10000 ble_connected=#{r[:a_link] == 'held'}\n"
    end

    def git(dir, *args)
      @calls << [:git, dir, *args]
      case args
      in ["rev-parse", "HEAD"] then @heads[dir] ? [true, "#{@heads[dir]}\n", 0] : [false, "not a repo", 0]
      in ["rev-parse", /\A(\w+):(.+)\z/]
        commit = $1 == "HEAD" ? @heads[dir] : $1
        [true, "#{@trees.fetch([commit, $2], "tree of #{$2}")}\n", 0]
      in ["status", "--porcelain", "--untracked-files=no", "--", *paths]
        [true, @dirty[dir].to_s.lines.select { |l| paths.any? { |p| l[3..].start_with?(p) } }.join, 0]
      in ["checkout", *, "--detach", sha] then (@heads[dir] = sha; [true, "", 0])
      in ["init", "--quiet", path] then (@heads[path] = nil; @exists[path] = true; [true, "", 0])
      in ["status", "--porcelain", "--untracked-files=no"] then [true, @dirty[dir].to_s, 0]
      in ["submodule", "update", *] then (@submodules.fetch(@heads[dir], {}).each { |path, sha| @heads[path] = sha }; [true, "", 0])
      else [true, "", 0]
      end
    end

    def rake(dir, *tasks, env: {}, bundle: true)
      @calls << [:rake, dir, *tasks, env]
      hook = @on_rake[tasks.first]
      hook.call(dir, env) if hook
      failing = @fail_rake[tasks.first]
      failing = failing.call if failing.respond_to?(:call)
      return [false, "boom", 0] if failing
      return [true, app_run(tasks.first, env), 0] if tasks.first.end_with?(":device:run")
      mac_rake(tasks.first, env)
      out = @rake_out[tasks.first]
      [true, out ? out.call : "done", 0]
    end

    APP_BUSY = "busy: robot is held by another controller or unreachable"

    def app_run(task, env)
      platform = task.split(":").first
      @clock += 9.5
      lines = env["APP_LAUNCH_ARGS"][/\A-StackchanBatch "(.*)"\z/, 1].split(";")
      custom = @app_out[platform]
      return custom.call(lines) if custom
      out = lines.map do |line|
        verb, arg = line.split(" ", 2)
        case verb
        when "connect" then app_take(platform) ? "Connected; RX value_handle bound" : APP_BUSY
        when "face" then app_take(platform) ? "OK face=#{arg}" : APP_BUSY
        when "selftest" then "OK selftest detail=\"<YL_actual:50,PU_actual:29>\\n\""
        end
      end
      @robot[:holder] = nil if @robot[:holder] == platform.to_sym
      (out.map { |l| "[batch] #{l}\n" } << "[batch] end\n").join
    end

    def app_take(platform)
      return false if @robot[:holder] && @robot[:holder] != platform.to_sym
      @robot[:holder] = platform.to_sym
      true
    end

    def mac_rake(task, env)
      case [task, env["NS"]]
      in ["pc:up", nil] then @robot.merge!(holder: :a, a_link: "held", connects: 1)
      in ["pc:down", nil] then (@robot[:holder] = nil if @robot[:holder] == :a; @robot[:a_link] = "down")
      else nil
      end
    end

    def cli(root, *args, env: {}, stdin: nil)
      @calls << [:cli, root, args, env, stdin]
      key = args.first == "remote" ? "remote #{args[1]}" : args.first
      out = @cli_out.fetch(key) { mac_cli(key, args) }
      out = out.call(args, env) if out.respond_to?(:call)
      code, text = out.is_a?(Array) ? out : [0, out]
      t = 0.1 + @calls.size * 0.001
      @clock += t
      [code.zero?, text, t, code]
    end

    BUSY = [8, "busy: the robot is held by another central\n"].freeze
    CALIBRATION = "[2/6] Align FORWARD... [3/6] LEFT MAX...  reading yaw_raw=2048 pitch_raw=2050\n" \
                  "\n{\"servo_yaw_zero\":2048,\"servo_pitch_zero\":2050,\"yaw_range_raw\":0,\"pitch_range_raw\":0," \
                  "\"forward_verify\":{\"yaw_delta\":1,\"pitch_delta\":-2}}\n"

    def mac_cli(key, args)
      r = @robot
      case key
      when "status" then status_line
      when "face"
        r[:connects] += 1 unless r[:a_link] == "held"
        r.merge!(holder: :a, a_link: "held")
        "OK face=#{args[1]}\n"
      when "selftest" then "OK selftest detail=\"<YL_actual:50,PU_actual:29>\\n\"\n"
      when "touch" then "[touch] listening (Ctrl-C to exit)...\ntouch zone=1 (back)\n"
      when "calibrate" then CALIBRATION
      when "chat" then "reply=こんにちは！元気だよ\n"
      else "OK"
      end
    end

    def prompt(question)
      @calls << [:prompt, question]
      @answers.shift
    end
  end

  def r2p2 = File.join(ROOT, "vendor", "R2P2-ESP32")
  def picoruby = File.join(r2p2, "components", "picoruby-esp32", "picoruby")
  def cache(name) = File.join(picoruby, "build", "repos", "esp32-picoruby", name)
  def darwin = File.join(ROOT, "vendor", "R2P2-darwin")
  def darwin_picoruby = File.join(darwin, "vendor", "picoruby")

  def boot(extra = "")
    "segment 1: paddr=001135c0 vaddr=3fc9e600 size\nI (1387) app_init: App version:      0.2.21-30-g#{FW['R2P2-ESP32'][0, 7]}\n" \
      "#{FW['boot_markers'].join("\n")}\n#{extra}"
  end

  def identity(version: "0.2.21-30-g#{FW['R2P2-ESP32'][0, 7]}", storage: "0x410000")
    "[flash_identity] partition nvs 0x9000 0x6000\n[flash_identity] partition factory 0x10000 0x400000\n" \
      "[flash_identity] partition storage #{storage} 0x100000\n[flash_identity] app_version #{version}\n[flash_identity] project R2P2-ESP32\n"
  end

  def setup
    @ops = FakeOps.new
    @ops.heads[ROOT] = ROOT_SHA
    @ops.heads[r2p2] = "0" * 40
    @ops.heads[picoruby] = "1" * 40
    @ops.submodules[FW["R2P2-ESP32"]] = { picoruby => FW["picoruby"] }
    @ops.on_rake["r2p2:setup"] = lambda do |dir, _env|
      FW["aot"].each { |name, sha| @ops.heads[File.join(dir, "build", "aot", name)] = sha }
    end
    @ops.rake_out["r2p2:flash_identity"] = -> { identity }
    @ops.on_rake["r2p2:reset_and_capture"] = ->(_dir, env) { @ops.boot_log[env["SERIAL_LOG"]] = boot }
    @ops.cli_out["servo"] = "servo detail=\"<YL_actual:50,PU_actual:29>\\n\""
    @ops.cli_out["remote servo"] = ".\n<YL_actual:40,PU_actual:19>\n"
    @ops.cli_out["remote face"] = ".\n"
    @ops.cli_out["remote text"] = ".\n"
    @ops.cli_out["remote servo_health"] = "<yaw_err:none,yaw_status:0,pitch_err:none,pitch_status:0>\n"
    @ops.cli_out["say"] = "OK say bytes=9000"
    @ops.cli_out["remote stack_free"] = "<stack_free:2024>\n"
    @ops.answers = %w[y] * 20
    @ops.files[File.join(ROOT, "apps/robot/app.rb")] = File.read(File.expand_path("../apps/robot/app.rb", __dir__))
  end

  def runner(rounds: 2) = Acceptance::Runner.new(lock: LOCK, root: ROOT, ops: @ops, bundled: BUNDLED, rounds: rounds, stamp: "t")

  def deployed(rounds: 2)
    t = runner(rounds: rounds)
    t.deploy
    t
  end

  def checked(from: nil, rounds: 2)
    t = deployed(rounds: rounds)
    t.check(from: from)
    t
  end

  def reloaded(t)
    later = runner
    later.report.merge!(JSON.parse(JSON.generate(t.report)))
    later
  end

  def names(part) = part["steps"].map { |s| s["name"] }
  def failed(part) = part["steps"].find { |s| s["ok"] == false }
  def step(report, name) = report["check"]["steps"].find { |s| s["name"] == name }
  def rakes = @ops.calls.select { |c| c[0] == :rake }
  def rake_tasks = rakes.map { |c| c[2] }
  def index_of(&blk) = @ops.calls.index(&blk)
  def cli_call?(c, *args, env: {}) = c[0] == :cli && c[2] == args && c[3] == env
  def rake_call?(c, task, env) = c[0] == :rake && c[2] == task && c[3] == env

  DEPLOY_STEPS = ["pin trees", "pins hold before setup", "r2p2:setup", "pins hold after setup", "r2p2:build_flash",
                  "pins hold after build", "app upload", "flash identity", "boot"].freeze
  WRITES = Acceptance::Runner::FIRMWARE_WRITES + Acceptance::Runner::APP_WRITES
  APP_STEPS = DEPLOY_STEPS.dup.insert(DEPLOY_STEPS.index("app upload"), "pins hold", "qemu gate").freeze
  GATE_ENV = { "QEMU_PROBE_APP" => "apps/robot/app.rb" }.freeze
  CHECK_STEPS = ["flash identity", "boot", "pc:up", "torque on", "face neutral", "led", "servo detail",
                 "remote servo detail", "servo health", "remote face", "say", "say routes", "timings", "quiet wait",
                 "selftest detail", "touch listen", "calibrate", "release and reconnect", "stack high-water",
                 "questions", "torque off", "chat"].freeze

  # --- deploy and check -----------------------------------------------------

  def test_deploy_check_and_darwin_pass
    t = checked
    t.run_darwin
    assert_equal "pass", t.report["verdict"]
    assert_equal DEPLOY_STEPS, names(t.report["deploy"])
    assert_equal CHECK_STEPS, names(t.report["check"])
    assert_equal ROOT_SHA, t.report["root"]
  end

  def test_a_deploy_alone_is_incomplete
    assert_equal "incomplete", deployed.report["verdict"]
  end

  def test_every_rake_and_cli_runs_in_this_checkout
    t = checked
    t.run_darwin
    assert_equal [ROOT], @ops.calls.select { |c| %i[rake cli].include?(c[0]) }.map { |c| c[1] }.uniq
  end

  def test_the_deploy_flashes_the_firmware_once_then_sends_the_locked_app
    t = deployed
    assert_equal ["r2p2:build_flash", "r2p2:upload_appmrb"], rake_tasks & WRITES
    assert_equal 1, rake_tasks.count("r2p2:build_flash")
    assert_equal [{ "SRC" => "apps/robot/app.rb" }], rakes.select { |c| c[2] == "r2p2:upload_appmrb" }.map(&:last)
    assert_not_include rake_tasks, "r2p2:build_flash_appmrb"
    assert t.report["deploy"]["steps"].all? { |s| s["ok"] }
  end

  def test_acceptance_app_resends_only_the_app_then_reads_the_identity_and_boots
    t = checked
    before = t.report["deploy"]["steps"].first(6).map(&:dup)
    @ops.calls.clear
    later = reloaded(t)
    later.upload_app
    assert_equal %w[r2p2:qemu_check r2p2:upload_appmrb r2p2:flash_identity r2p2:reset_and_capture r2p2:reset], rake_tasks
    assert_equal GATE_ENV, rakes.first.last
    assert_equal 10, later.report["resets"]
    assert_empty rake_tasks & Acceptance::Runner::FIRMWARE_WRITES
    assert_equal APP_STEPS, names(later.report["deploy"])
    assert_equal before, later.report["deploy"]["steps"].first(6)
    assert_equal({ "steps" => [], "timings" => {}, "human" => {} }, later.report["check"])
    assert_equal "incomplete", later.report["verdict"]
    later.check
    later.run_darwin
    assert_equal "pass", later.report["verdict"]
  end

  def test_the_deploy_writes_the_app_only_in_its_app_upload_and_acceptance_app_never_writes_firmware
    t = runner
    refused = []
    try = ->(task) { t.rake(task) rescue refused << task }
    @ops.on_rake["r2p2:build_flash"] = ->(_d, _e) { Acceptance::Runner::APP_WRITES.each(&try) }
    t.deploy
    assert_equal Acceptance::Runner::APP_WRITES, refused
    refused.clear
    @ops.on_rake["r2p2:upload_appmrb"] = ->(_d, _e) { Acceptance::Runner::FIRMWARE_WRITES.each(&try) }
    t.upload_app
    assert_equal Acceptance::Runner::FIRMWARE_WRITES, refused
  end

  def test_acceptance_app_retries_an_app_upload_that_failed_in_the_deploy
    @ops.fail_rake["r2p2:upload_appmrb"] = true
    t = deployed
    assert_equal "app upload", failed(t.report["deploy"])["name"]
    assert_raise(Acceptance::Stop) { reloaded(t).check }
    @ops.fail_rake.delete("r2p2:upload_appmrb")
    later = reloaded(t)
    later.upload_app
    assert_equal APP_STEPS, names(later.report["deploy"])
    assert later.report["deploy"]["steps"].all? { |s| s["ok"] }
  end

  def test_a_pin_moved_since_the_deploy_stops_acceptance_app_before_the_gate_and_the_board
    t = deployed
    @ops.heads[cache("picoruby-ili9342")] = "e" * 40
    @ops.calls.clear
    t.upload_app
    assert_empty rakes
    assert_equal "pins hold", failed(t.report["deploy"])["name"]
    assert_match(/picoruby-ili9342/, failed(t.report["deploy"])["detail"])
    assert_equal "fail", t.report["verdict"]
  end

  def test_acceptance_app_runs_the_qemu_gate_before_any_serial_task
    t = deployed
    @ops.calls.clear
    t.upload_app
    serial = rakes.index { |c| Acceptance::Ops::DEVICE_TASKS.include?(c[2]) }
    assert_equal [:rake, ROOT, "r2p2:qemu_check", GATE_ENV], rakes.first
    assert_operator rakes.index(rakes.first), :<, serial
    assert_not_include Acceptance::Ops::DEVICE_TASKS, "r2p2:qemu_check"
    assert_not_include WRITES, "r2p2:qemu_check"
  end

  def test_a_failing_qemu_gate_stops_acceptance_app_before_the_board_and_a_later_acceptance_app_retries
    t = deployed
    @ops.fail_rake["r2p2:qemu_check"] = true
    @ops.calls.clear
    t.upload_app
    assert_equal ["r2p2:qemu_check"], rake_tasks
    assert_equal "qemu gate", failed(t.report["deploy"])["name"]
    assert_equal "fail", t.report["verdict"]
    assert_raise(Acceptance::Stop) { reloaded(t).check }
    @ops.fail_rake.delete("r2p2:qemu_check")
    later = reloaded(t)
    later.upload_app
    assert_equal APP_STEPS, names(later.report["deploy"])
    later.check
    later.run_darwin
    assert_equal "pass", later.report["verdict"]
  end

  def test_acceptance_app_without_an_ok_firmware_deploy_stops
    assert_raise(Acceptance::Stop) { runner.upload_app }
    @ops.fail_rake["r2p2:build_flash"] = true
    t = deployed
    @ops.calls.clear
    assert_raise(Acceptance::Stop) { reloaded(t).upload_app }
    assert_empty rakes
  end

  def test_the_check_never_runs_a_flash_writing_task
    t = deployed
    @ops.calls.clear
    t.check
    t.run_darwin
    assert_empty rake_tasks & WRITES
    assert_equal "pass", t.report["verdict"]
  end

  def test_the_guard_stops_a_flash_write_outside_the_deploy
    t = deployed
    @ops.calls.clear
    WRITES.each do |task|
      assert_raise(Acceptance::Stop) { t.rake(task) }
    end
    assert_empty rakes
  end

  def test_a_second_deploy_into_the_same_report_stops
    t = deployed
    @ops.calls.clear
    assert_raise(Acceptance::Stop) { t.deploy }
    assert_raise(Acceptance::Stop) { reloaded(t).deploy }
    assert_empty rakes
  end

  def test_a_changed_lock_stops_check_and_acceptance_app_before_touching_anything
    t = checked
    lock = Marshal.load(Marshal.dump(LOCK))
    lock["firmware"]["repos"]["picoruby-scservo"] = "c" * 40
    later = Acceptance::Runner.new(lock: lock, root: ROOT, ops: @ops, bundled: BUNDLED, rounds: 2, stamp: "t")
    later.report.merge!(JSON.parse(JSON.generate(t.report)))
    @ops.calls.clear
    assert_raise_message(/lock\.yml differs/) { later.check }
    assert_raise_message(/lock\.yml differs/) { later.upload_app }
    assert_empty @ops.calls
  end

  def test_a_checkout_moved_outside_what_the_board_runs_checks_and_resends_the_app
    t = checked
    @ops.heads[ROOT] = "b" * 40
    later = reloaded(t)
    later.check
    assert_equal "b" * 40, later.report["check"]["root"]
    later.upload_app
    assert_equal "b" * 40, later.report["deploy"]["app_root"]
    assert_equal ROOT_SHA, later.report["root"]
  end

  def test_a_changed_firmware_input_stops_check_and_acceptance_app_before_touching_anything
    t = checked
    @ops.heads[ROOT] = "b" * 40
    @ops.trees[["b" * 40, "aot/kernels"]] = "another aot"
    @ops.calls.clear
    assert_raise_message(/aot\/kernels differ from aaaaaaa, which the deploy built; that is another firmware/) { reloaded(t).check }
    assert_raise_message(/aot\/kernels differ from aaaaaaa, which the deploy built/) { reloaded(t).upload_app }
    assert_empty @ops.calls.reject { |c| c[0] == :git && %w[rev-parse status].include?(c[2]) }
  end

  def test_a_changed_aot_readme_is_not_a_firmware_input
    t = checked
    @ops.heads[ROOT] = "b" * 40
    @ops.trees[["b" * 40, "aot"]] = "another aot tree"
    later = reloaded(t)
    later.check
    assert_equal "pass", later.report["verdict"]
  end

  def test_firmware_inputs_covers_exactly_what_the_aot_build_reads
    assert_equal %w[build_config/esp32-stackchan.rb aot/kernels aot/mcu-shim aot/multicore.pin aot/suppify.pin
                   tools/aot mrbgems/picoruby-stackchan-protocol], Acceptance::Runner::FIRMWARE_INPUTS
    assert_not_include Acceptance::Runner::FIRMWARE_INPUTS, "aot"
    assert_not_include Acceptance::Runner::FIRMWARE_INPUTS, "aot/README.md"
    assert_not_include Acceptance::Runner::FIRMWARE_INPUTS, "aot/test"
  end

  def test_a_changed_app_input_stops_the_check_until_acceptance_app_sends_it
    t = checked
    @ops.heads[ROOT] = "b" * 40
    @ops.trees[["b" * 40, "mrbgems/picoruby-stackchan-robot"]] = "new robot engine"
    @ops.calls.clear
    assert_raise_message(/picoruby-stackchan-robot differ from aaaaaaa, which the board runs; run acceptance:app/) { reloaded(t).check }
    assert_empty @ops.calls.reject { |c| c[0] == :git && %w[rev-parse status].include?(c[2]) }
    later = reloaded(t)
    later.upload_app
    assert_equal "b" * 40, later.report["deploy"]["app_root"]
    later.check
    later.run_darwin
    assert_equal "pass", later.report["verdict"]
  end

  def test_local_changes_in_what_the_board_runs_stop_the_check_and_elsewhere_do_not
    t = checked
    @ops.dirty[ROOT] = " M HANDOFF.md\n"
    reloaded(t).check
    @ops.dirty[ROOT] = " M apps/robot/app.rb\n"
    assert_raise_message(/local changes/) { reloaded(t).check }
    @ops.dirty[ROOT] = " M mrbgems/picoruby-stackchan-protocol/mrblib/frame_parser.rb\n"
    assert_raise_message(/local changes/) { reloaded(t).upload_app }
  end

  def test_a_check_without_a_deploy_stops
    assert_raise(Acceptance::Stop) { runner.check }
    assert_empty rakes
  end

  def test_a_check_after_a_failed_deploy_stops
    @ops.fail_rake["r2p2:setup"] = true
    t = deployed
    assert_equal "fail", t.report["verdict"]
    @ops.calls.clear
    assert_raise(Acceptance::Stop) { reloaded(t).check }
    assert_empty rakes
  end

  def test_a_deploy_starts_an_empty_check
    t = checked
    t.report["deploy"] = nil
    t.deploy
    assert_equal({ "steps" => [], "timings" => {}, "human" => {} }, t.report["check"])
  end

  # --- pins -----------------------------------------------------------------

  def test_every_tree_is_pinned_before_the_first_build
    deployed
    first_rake = @ops.calls.index { |c| c[0] == :rake }
    pins = @ops.calls[0...first_rake].select { |c| c[0] == :git && c[2] == "checkout" }.map { |c| [c[1], c.last] }
    assert_include pins, [r2p2, FW["R2P2-ESP32"]]
    FW["repos"].each { |name, sha| assert_include pins, [cache(name), sha] }
    assert_include pins, [darwin, LOCK["darwin"]["R2P2-darwin"]]
    assert_include pins, [darwin_picoruby, LOCK["darwin"]["picoruby"]]
    assert_equal "r2p2:setup", rakes.first[2]
  end

  def test_a_dirty_checkout_stops_the_deploy_before_anything_builds
    @ops.dirty[ROOT] = " M acceptance/runner.rb\n"
    t = deployed
    assert_equal "pin trees", failed(t.report["deploy"])["name"]
    assert_match(/local changes/, failed(t.report["deploy"])["detail"])
    assert_empty rakes
  end

  def test_a_moved_cache_keeps_its_old_commit_on_a_branch
    @ops.heads[cache("picoruby-ili9342")] = "f" * 40
    deployed
    assert_include @ops.calls, [:git, cache("picoruby-ili9342"), "branch", "keep-#{'f' * 40}", "HEAD"]
    assert_equal FW["repos"]["picoruby-ili9342"], @ops.heads[cache("picoruby-ili9342")]
  end

  def test_a_pin_that_moves_during_the_build_stops_the_deploy
    @ops.on_rake["r2p2:build_flash"] = ->(_d, _e) { @ops.heads[cache("picoruby-ili9342")] = "e" * 40 }
    t = deployed
    assert_equal "fail", t.report["verdict"]
    assert_equal "pins hold after build", failed(t.report["deploy"])["name"]
    assert_not_include rake_tasks, "r2p2:flash_identity"
  end

  def test_a_checkout_that_moves_during_the_build_stops_the_deploy
    @ops.on_rake["r2p2:build_flash"] = ->(_d, _e) { @ops.heads[ROOT] = "b" * 40 }
    t = deployed
    assert_equal "pins hold after build", failed(t.report["deploy"])["name"]
  end

  def test_local_changes_in_r2p2_stop_the_deploy
    @ops.dirty[r2p2] = " M components/picoruby-esp32/CMakeLists.txt\n"
    t = deployed
    assert_equal "pins hold before setup", failed(t.report["deploy"])["name"]
    assert_match(/local changes/, failed(t.report["deploy"])["detail"])
  end

  def test_aot_pins_are_checked_after_setup
    @ops.on_rake["r2p2:setup"] = ->(_d, _e) {}
    t = deployed
    assert_equal "pins hold after setup", failed(t.report["deploy"])["name"]
  end

  # --- identity and boot ------------------------------------------------------

  def test_the_deploy_sends_the_app_after_the_flash_then_reads_the_identity_and_boots
    deployed
    assert_equal %w[r2p2:setup r2p2:build_flash r2p2:upload_appmrb r2p2:flash_identity r2p2:reset_and_capture r2p2:reset], rake_tasks
  end

  def test_a_fault_in_the_boot_log_fails_the_boot
    @ops.on_rake["r2p2:reset_and_capture"] = ->(_d, env) { @ops.boot_log[env["SERIAL_LOG"]] = boot("***ERROR*** A stack overflow in task picoruby_task") }
    t = deployed
    assert_equal "boot", failed(t.report["deploy"])["name"]
  end

  def test_a_missing_marker_fails_the_boot
    t = deployed
    @ops.on_rake["r2p2:reset_and_capture"] = ->(_d, env) { @ops.boot_log[env["SERIAL_LOG"]] = boot.sub("[boot] step:led-init-ok", "") }
    t.check
    assert_equal "boot", failed(t.report["check"])["name"]
    assert_match(/led-init-ok/, failed(t.report["check"])["detail"])
    assert_not_include rake_tasks, "pc:up"
  end

  def test_an_identity_that_is_not_the_locked_firmware_stops_the_check_before_boot_and_pc_up
    t = deployed
    @ops.calls.clear
    @ops.rake_out["r2p2:flash_identity"] = -> { identity(version: "0.2.21-30-g2f18720") }
    t.check
    assert_equal "flash identity", failed(t.report["check"])["name"]
    assert_match(/App version/, failed(t.report["check"])["detail"])
    assert_equal ["r2p2:flash_identity"], rake_tasks
  end

  def test_a_dirty_app_version_is_not_the_locked_firmware
    @ops.rake_out["r2p2:flash_identity"] = -> { identity(version: "0.2.21-30-g#{FW['R2P2-ESP32'][0, 7]}-dirty") }
    t = deployed
    assert_equal "flash identity", failed(t.report["deploy"])["name"]
  end

  def test_the_flash_must_put_storage_where_the_tooling_writes
    @ops.rake_out["r2p2:flash_identity"] = -> { identity(storage: "0x310000") }
    t = deployed
    assert_match(/storage at "0x310000"/, failed(t.report["deploy"])["detail"])
  end

  def test_the_check_resets_out_of_the_capture_s_download_mode_right_before_pc_up
    t = deployed
    @ops.calls.clear
    t.check
    seq = @ops.calls.reject { |c| c[0] == :now }
    cap = seq.index { |c| c[0] == :rake && c[2] == "r2p2:reset_and_capture" }
    assert_equal({ "SERIAL_LOG" => File.join(ROOT, "build", "acceptance", "boot.log"), "DURATION" => "25" }, seq[cap].last)
    assert_equal [[:rake, ROOT, "r2p2:reset", {}], [:rake, ROOT, "pc:up", {}]], seq[cap + 1, 2]
  end

  # --- pc:up ---------------------------------------------------------------

  def test_pc_up_succeeds_on_a_later_try
    tries = 0
    @ops.fail_rake["pc:up"] = -> { (tries += 1) < 3 }
    t = checked
    assert_match(/\Aup after 3 tries, \d+\.\d s\z/, step(t.report, "pc:up")["detail"])
    first = index_of { |c| rake_call?(c, "pc:up", {}) }
    assert_equal [[:sleep, 5], [:sleep, 5]], @ops.calls[first..].select { |c| c[0] == :sleep }.first(2)
    t.run_darwin
    assert_equal "pass", t.report["verdict"]
  end

  def test_pc_up_fails_after_the_last_try
    @ops.fail_rake["pc:up"] = true
    t = checked
    assert_equal "pc:up", failed(t.report["check"])["name"]
    assert_equal Acceptance::Runner::PC_UP_TRIES, rakes.count { |c| c[2] == "pc:up" }
    assert_equal [[:sleep, 5]] * (Acceptance::Runner::PC_UP_TRIES - 1), @ops.calls.select { |c| c[0] == :sleep }
    assert_equal "fail", t.report["verdict"]
  end

  # --- resets -----------------------------------------------------------------

  def test_each_board_reset_is_recorded_across_deploy_and_check
    t = deployed
    assert_equal 4, t.report["resets"]
    t.check
    assert_equal 7, t.report["resets"]
    assert_match(/Board resets: 7\n/, t.markdown)
  end

  def test_resets_are_recorded_and_never_stop_a_run_and_app_uploads_are_not_resets
    t = deployed
    t.report["resets"] = 1000
    3.times { t.upload_app }
    assert_equal 1000 + 3 * 3, t.report["resets"]
    t.check
    t.run_darwin
    assert_equal "pass", t.report["verdict"]
  end

  # --- FROM= ------------------------------------------------------------------

  def test_from_keeps_the_earlier_steps_and_reruns_the_rest
    t = checked
    before = t.report["check"]["steps"].map(&:dup)
    t.report["check"]["timings"]["face"] = [9.0]
    t.report["check"]["timings"]["release and reconnect"] = [9.0]
    later = reloaded(t)
    @ops.calls.clear
    later.check(from: "calibrate")
    c = later.report["check"]
    assert_equal CHECK_STEPS, names(c)
    i = CHECK_STEPS.index("calibrate")
    assert_equal before.first(i), c["steps"].first(i)
    assert_equal [9.0], c["timings"]["face"]
    assert_not_equal [9.0], c["timings"]["release and reconnect"]
    assert_not_include rake_tasks, "r2p2:flash_identity"
    assert_equal "calibrate", @ops.calls.find { |x| x[0] == :cli }[2].first
    assert_equal 30, later.report["check"]["steps"].find { |s| s["name"] == "quiet wait" }["detail"].to_i
    assert_include @ops.calls, [:sleep, 30]
  end

  def test_from_before_the_questions_asks_them_again_and_after_keeps_the_answers
    t = checked
    @ops.answers = []
    later = reloaded(t)
    later.check(from: "torque off")
    assert_equal %w[y] * Acceptance::Runner::QUESTIONS.size, later.report["check"]["human"].values.map { |h| h["answer"] }
    later.check(from: "stack high-water")
    assert_equal [nil] * Acceptance::Runner::QUESTIONS.size, later.report["check"]["human"].values.map { |h| h["answer"] }
  end

  def test_from_with_an_earlier_failed_step_stops
    @ops.cli_out["selftest"] = "OK selftest\n"
    t = checked
    assert_equal "selftest detail", failed(t.report["check"])["name"]
    @ops.calls.clear
    assert_raise(Acceptance::Stop) { reloaded(t).check(from: "calibrate") }
    assert_empty @ops.calls.select { |c| %i[rake cli].include?(c[0]) }
  end

  def test_from_with_a_step_the_previous_check_never_reached_stops
    @ops.cli_out["say"] = "OK say bytes=3000"
    t = checked
    assert_raise(Acceptance::Stop) { reloaded(t).check(from: "calibrate") }
  end

  def test_from_an_unknown_step_stops
    t = checked
    assert_raise(Acceptance::Stop) { t.check(from: "no such step") }
  end

  def test_from_the_failed_step_reruns_it
    @ops.cli_out["selftest"] = "OK selftest\n"
    t = checked
    @ops.cli_out.delete("selftest")
    later = reloaded(t)
    later.check(from: "selftest detail")
    assert_nil failed(later.report["check"])
    later.run_darwin
    assert_equal "pass", later.report["verdict"]
  end

  # --- robot steps --------------------------------------------------------------

  def test_remote_servo_must_answer_the_detail_line
    @ops.cli_out["remote servo"] = ".\n"
    t = checked
    assert_equal "remote servo detail", failed(t.report["check"])["name"]
  end

  def test_less_than_512_b_of_stack_left_stops_the_check_and_856_b_passes
    @ops.cli_out["remote stack_free"] = "<stack_free:511>\n"
    assert_equal "stack high-water", failed(checked.report["check"])["name"]
    setup
    @ops.cli_out["remote stack_free"] = "<stack_free:856>\n"
    assert_equal "856 B free", step(checked.report, "stack high-water")["detail"]
  end

  def test_a_firmware_without_the_stack_reading_stops_the_check
    @ops.cli_out["remote stack_free"] = "<stack_free:unknown>\n"
    assert_equal "stack high-water", failed(checked.report["check"])["name"]
  end

  def test_say_must_span_more_than_two_multicore_chunks
    @ops.cli_out["say"] = "OK say bytes=3000"
    assert_equal "say", failed(checked.report["check"])["name"]
  end

  def test_timings_hold_every_series_for_the_rounds
    t = checked(rounds: 3)
    tm = t.report["check"]["timings"]
    assert_equal 3, tm["servo"].size
    assert_equal 3, tm["face"].size
    assert_equal 3, tm["led"].size
    assert_equal 3, tm["text"].size
  end

  def test_measure_series_names_drop_the_old_text_vs_remote_comparison
    tm = checked(rounds: 2).report["check"]["timings"]
    assert_equal %w[servo face led text], %w[servo face led text] & tm.keys
    assert_empty tm.keys & ["servo text", "servo remote", "face joy", "led (floor)", "subtitle 19 glyphs"]
  end

  def test_connect_ms_is_parsed_from_the_status_line_after_the_first_connect
    @ops.cli_out["status"] = "link=held connects=1 releases=0 last_connect_ms=842 hold_ms=10000 ble_connected=true\n"
    t = checked
    assert_equal [842], t.report["check"]["timings"]["connect ms"]
  end

  def test_a_failing_drb_say_is_recorded_without_stopping_the_check_or_failing_the_verdict
    @ops.cli_out["say"] = lambda do |args, _env|
      args.include?("--drb") ? [1, "error: drb route failed\n"] : "OK say bytes=9000"
    end
    t = checked
    assert_equal "pass", t.report["verdict"]
    assert step(t.report, "say")["ok"]
    assert step(t.report, "say routes")["ok"]
    assert_equal 1, t.report["check"]["timings"]["say drb"].size
    assert_equal 1, t.report["check"]["timings"]["say direct"].size
  end

  def test_unanswered_questions_leave_it_incomplete_until_answered
    @ops.answers = []
    t = checked
    t.run_darwin
    assert_equal "incomplete", t.report["verdict"]
    @ops.answers = %w[y] * 20
    t.answer
    assert_equal "pass", t.report["verdict"]
  end

  def test_a_check_with_every_answer_y_passes_without_darwin
    t = checked
    assert_nil t.report["darwin"]
    assert_equal "pass", t.report["verdict"]
  end

  def test_a_no_fails_it
    @ops.answers = %w[y n] + %w[y] * 20
    t = checked
    t.run_darwin
    assert_equal "fail", t.report["verdict"]
  end

  # --- controller -------------------------------------------------------------

  CONTROLLER_STEPS = ["quiet wait", "selftest detail", "touch listen", "calibrate", "release and reconnect"].freeze

  def test_the_controller_steps_run_in_order_between_timings_and_stack_high_water
    n = names(checked.report["check"])
    assert_equal CONTROLLER_STEPS, n[n.index("timings") + 1, CONTROLLER_STEPS.size]
    assert_equal "stack high-water", n[n.index("timings") + 1 + CONTROLLER_STEPS.size]
  end

  def test_every_controller_step_passes_with_its_machine_answer
    r = checked.report
    assert_equal [], r["check"]["steps"].reject { |s| s["ok"] }
    assert_equal "30 s", step(r, "quiet wait")["detail"]
    assert_equal "<YL_actual:50,PU_actual:29>", step(r, "selftest detail")["detail"]
    assert_equal "touch zone=1 (back)", step(r, "touch listen")["detail"]
    assert_equal "yaw_zero 2048, pitch_zero 2050, verify delta 1/-2", step(r, "calibrate")["detail"]
    assert_equal "reply=こんにちは！元気だよ", step(r, "chat")["detail"]
    assert_match(/\Arelease seen: yes, reconnect \+ face \d\.\d\d s\z/, step(r, "release and reconnect")["detail"])
    assert_equal 1, r["check"]["timings"]["release and reconnect"].size
  end

  def test_quiet_wait_is_hold_plus_release_after_plus_five_seconds
    assert_equal 30, runner.quiet_wait_s
    checked
    assert_equal [30], @ops.calls.select { |c| c[0] == :sleep }.map(&:last).uniq
  end

  def test_quiet_wait_follows_the_firmware_app_and_the_status_line
    @ops.files[File.join(ROOT, "apps/robot/app.rb")] = "StackChan.robot do |bot|\n  bot.release_after 4_000\nend.run\n"
    @ops.cli_out["status"] = "link=held connects=1 releases=0 last_connect_ms=1 hold_ms=3000\n"
    assert_equal 12, runner.quiet_wait_s
  end

  def test_an_app_without_release_after_stops_the_check
    @ops.files[File.join(ROOT, "apps/robot/app.rb")] = "StackChan.robot do |bot|\nend.run\n"
    assert_equal "quiet wait", failed(checked.report["check"])["name"]
  end

  def test_touch_asks_the_operator_then_listens_for_one_touch
    checked
    notice = index_of { |c| c == [:notice, "touch the back of the head"] }
    listen = index_of { |c| cli_call?(c, "touch", "listen", "--count", "1", "--timeout", "30") }
    assert_operator notice, :<, listen
    assert @ops.calls[0...listen].any? { |c| cli_call?(c, "remote", "stack_free") },
           "say routes should have read stack_free before touch listen"
    assert @ops.calls[listen..].any? { |c| cli_call?(c, "remote", "stack_free") },
           "stack high-water should read stack_free after touch listen"
  end

  def test_a_head_nobody_touches_neither_stops_the_check_nor_blocks_the_pass
    @ops.cli_out["touch"] = [1, "[touch] listening (Ctrl-C to exit)...\n[touch] timed out\n"]
    t = checked
    s = step(t.report, "touch listen")
    assert_nil s["ok"]
    assert_match(/not touched within 30 s/, s["detail"])
    assert_equal CHECK_STEPS, names(t.report["check"])
    assert_equal "pass", t.report["verdict"]
  end

  def test_selftest_without_a_detail_line_stops_the_check
    @ops.cli_out["selftest"] = "OK selftest\n"
    assert_equal "selftest detail", failed(checked.report["check"])["name"]
  end

  def run_without_a_tty
    @ops.tty = false
    @ops.answers = []
    t = checked
    t.run_darwin
    assert_equal "incomplete", t.report["verdict"]
    @ops.answers = %w[y] * 20
    reloaded(t)
  end

  def touch_steps(report) = report["check"]["steps"].select { |s| s["name"] == "touch listen" }

  def test_acceptance_touch_listens_and_completes_the_verdict
    later = run_without_a_tty
    @ops.tty = true
    @ops.calls.clear
    later.run_touch
    assert_equal [[:notice, "touch the back of the head"],
                  [:cli, ROOT, %w[touch listen --count 1 --timeout 30], {}, nil]], @ops.calls
    assert_equal [{ "name" => "touch listen", "ok" => true, "detail" => "touch zone=1 (back)" }], touch_steps(later.report)
    later.answer
    assert_equal "pass", later.report["verdict"]
    assert_match(/\| touch listen \| ok \| touch zone=1 \(back\) \|/, later.markdown)
  end

  def test_acceptance_touch_that_times_out_leaves_it_untouched_and_the_answers_pass
    later = run_without_a_tty
    @ops.tty = true
    @ops.cli_out["touch"] = [1, "[touch] listening (Ctrl-C to exit)...\n[touch] timed out\n"]
    later.run_touch
    steps = touch_steps(later.report)
    assert_equal 1, steps.size
    assert_nil steps.first["ok"]
    later.answer
    assert_equal "pass", later.report["verdict"]
  end

  def test_acceptance_touch_without_a_tty_leaves_it_incomplete
    later = run_without_a_tty
    @ops.calls.clear
    later.run_touch
    assert_empty @ops.calls.select { |c| c[0] == :cli }
    assert_nil touch_steps(later.report).first["ok"]
    assert_equal "incomplete", later.report["verdict"]
  end

  def test_acceptance_touch_without_a_check_stops
    assert_raise(Acceptance::Stop) { deployed.tap { |t| t.report["check"] = nil }.run_touch }
  end

  def test_touch_without_a_tty_is_incomplete_and_the_check_goes_on
    @ops.tty = false
    t = checked
    s = step(t.report, "touch listen")
    assert_nil s["ok"]
    assert_match(/incomplete/, s["detail"])
    assert_nil index_of { |c| c[0] == :cli && c[2].first == "touch" }
    assert_include names(t.report["check"]), "stack high-water"
    assert_match(/\| touch listen \| incomplete \|/, t.markdown)
  end

  def test_from_keeps_an_incomplete_touch_for_acceptance_touch_to_fill
    @ops.tty = false
    t = checked
    later = reloaded(t)
    later.check(from: "calibrate")
    assert_nil step(later.report, "touch listen")["ok"]
  end

  def test_calibrate_feeds_five_enters_and_reads_the_json_line
    checked
    c = @ops.calls.find { |x| x[0] == :cli && x[2].first == "calibrate" }
    assert_equal %w[calibrate --no-torque-toggle --format json --samples 3], c[2]
    assert_equal "\n" * 5, c[4]
  end

  def test_calibrate_that_needs_manual_calibration_stops_the_check
    @ops.cli_out["calibrate"] = [6, "[FAIL] device returned unknown raw position (manual calibration needed)\n"]
    t = checked
    assert_equal "calibrate", failed(t.report["check"])["name"]
    assert_match(/exit 6/, failed(t.report["check"])["detail"])
  end

  def test_calibrate_whose_last_line_is_not_json_stops_the_check
    @ops.cli_out["calibrate"] = "[6/6] Re-align FORWARD\n[WARN] verify delta exceeded 3; review before paste.\n"
    assert_equal "calibrate", failed(checked.report["check"])["name"]
  end

  def test_calibrate_with_a_forward_verify_delta_over_three_stops_the_check
    @ops.cli_out["calibrate"] = FakeOps::CALIBRATION.sub('"pitch_delta":-2', '"pitch_delta":-4')
    assert_equal "calibrate", failed(checked.report["check"])["name"]
  end

  def test_chat_runs_last_on_the_running_mac_without_speaking
    checked
    torque_off = @ops.calls.rindex { |c| cli_call?(c, "torque", "off") }
    assert_equal [[:cli, ROOT, %w[chat こんにちは --no-speak], {}, nil]], @ops.calls[torque_off + 1..]
    assert_empty rakes.select { |c| c[3]["STUB"] }
  end

  def test_a_reply_that_is_none_or_from_the_stub_sidecar_fails_the_chat
    ["reply=(none)\n", "reply=stub返答:こんにちは\n", "reply=\n", [1, "error: sidecar\n"]].each do |out|
      setup
      @ops.cli_out["chat"] = out
      t = checked
      assert_equal "chat", failed(t.report["check"])["name"], out.inspect
      assert_equal "fail", t.report["verdict"]
      assert step(t.report, "torque off")["ok"]
    end
  end

  def test_release_is_seen_and_the_next_face_reconnects_once
    checked
    cal = index_of { |c| c[0] == :cli && c[2].first == "calibrate" }
    joy = cal + @ops.calls[cal..].index { |c| cli_call?(c, "face", "joy") }
    assert_equal [:sleep, 30], @ops.calls[joy - 2]
    assert cli_call?(@ops.calls[joy - 1], "status")
  end

  def test_connects_that_do_not_grow_stop_the_check
    @ops.cli_out["status"] = "link=held connects=1 releases=0 last_connect_ms=1 hold_ms=10000\n"
    t = checked
    assert_equal "release and reconnect", failed(t.report["check"])["name"]
    assert_match(/connects/, failed(t.report["check"])["detail"])
  end

  # --- darwin -----------------------------------------------------------------

  APP_ENV = { "APP_CONSOLE" => "1", "APP_LAUNCH_ARGS" => '-StackchanBatch "connect;face joy;selftest"' }.freeze

  def darwin_step(report, name) = report["darwin"]["steps"].find { |s| s["name"] == name }
  def darwin_failed(report) = report["darwin"]["steps"].find { |s| !s["ok"] }

  def run_darwin_only
    t = runner
    t.run_darwin
    t.report
  end

  def test_darwin_builds_both_apps_in_this_checkout_at_the_locked_r2p2_darwin
    run_darwin_only
    builds = rakes.reject { |c| c[2].end_with?(":device:run") }.map { |c| [c[1], c[2]] }
    assert_equal %w[ios:device:lib ios:gen ios:device:build watchos:device:lib watchos:gen watchos:device:build]
                   .map { |t| [ROOT, t] }, builds
    assert_equal LOCK["darwin"]["R2P2-darwin"], @ops.heads[darwin]
    assert_equal LOCK["darwin"]["picoruby"], @ops.heads[darwin_picoruby]
  end

  def test_each_app_runs_connect_face_and_selftest_once_on_its_console_after_the_builds
    run_darwin_only
    runs = rakes.select { |c| c[2].end_with?(":device:run") }
    assert_equal [["ios:device:run", APP_ENV], ["watchos:device:run", APP_ENV]], runs.first(2).map { |c| [c[2], c[3]] }
    last_build = @ops.calls.rindex { |c| c[0] == :rake && c[2] == "watchos:device:build" }
    assert_operator last_build, :<, @ops.calls.index(runs.first)
  end

  def test_darwin_passes_on_the_machine_answers_alone
    r = run_darwin_only
    assert_equal ["pin R2P2-darwin", "ios:device:lib", "ios:gen", "ios:device:build", "watchos:device:lib",
                  "watchos:gen", "watchos:device:build", "pin R2P2-darwin holds", "quiet wait", "iPhone batch",
                  "Watch batch", "hand-off Mac → iPhone → Watch → Mac"], names(r["darwin"])
    assert r["darwin"]["steps"].all? { |s| s["ok"] }
    assert_equal "<YL_actual:50,PU_actual:29>", darwin_step(r, "iPhone batch")["detail"]
    assert_empty @ops.calls.select { |c| c[0] == :prompt }
  end

  def test_darwin_hand_off_order
    run_darwin_only
    start = @ops.calls.rindex { |c| c[0] == :rake && c[2] == "watchos:device:run" && c[3] == APP_ENV } + 1
    seq = @ops.calls[start..].reject { |c| c[0] == :now }.map do |c|
      case c[0]
      when :cli then c[2]
      when :rake then [c[2], c[3]["APP_LAUNCH_ARGS"]]
      else c
      end
    end
    assert_equal [[:sleep, 30], %w[face neutral], %w[status], [:sleep, 30],
                  ["ios:device:run", '-StackchanBatch "face joy"'], [:sleep, 30],
                  ["watchos:device:run", '-StackchanBatch "face smile"'], [:sleep, 30],
                  %w[face neutral], %w[status]], seq
  end

  def test_the_hand_off_records_seconds_for_each_device
    r = run_darwin_only
    assert_equal ["hand-off iPhone", "hand-off Watch", "hand-off Mac"], r["darwin"]["timings"].keys
    assert r["darwin"]["timings"].values.all? { |v| v.size == 1 && v[0] > 0 }
    assert_match(/iPhone \d+\.\d\d s, Watch \d+\.\d\d s, Mac \d+\.\d\d s/,
                 darwin_step(r, "hand-off Mac → iPhone → Watch → Mac")["detail"])
  end

  def test_a_failing_device_build_stops_darwin_before_any_app_runs
    @ops.fail_rake["watchos:device:build"] = true
    r = run_darwin_only
    assert_equal "watchos:device:build", darwin_failed(r)["name"]
    assert_nil rakes.find { |c| c[2].end_with?(":device:run") }
    assert_equal "fail", r["verdict"]
  end

  def test_an_iphone_that_never_connects_fails_its_batch
    @ops.app_out["ios"] = ->(_lines) { "[batch] busy: robot is held by another controller or unreachable\n[batch] end\n" }
    r = run_darwin_only
    assert_equal "iPhone batch", darwin_failed(r)["name"]
    assert_match(/Connected; RX value_handle bound/, darwin_failed(r)["detail"])
    assert_equal "fail", r["verdict"]
  end

  def test_an_app_whose_face_is_not_ok_fails_its_batch
    @ops.app_out["watchos"] = ->(_lines) { "[batch] Connected; RX value_handle bound\n[batch] error: timeout\n[batch] end\n" }
    r = run_darwin_only
    assert_equal "Watch batch", darwin_failed(r)["name"]
    assert_match(/OK face=joy/, darwin_failed(r)["detail"])
  end

  def test_an_app_without_the_selftest_detail_fails_its_batch
    @ops.app_out["ios"] = lambda do |_lines|
      "[batch] Connected; RX value_handle bound\n[batch] OK face=joy\n[batch] OK selftest detail=nil\n[batch] end\n"
    end
    r = run_darwin_only
    assert_equal "iPhone batch", darwin_failed(r)["name"]
    assert_match(/selftest detail/, darwin_failed(r)["detail"])
  end

  def test_an_app_that_never_ends_its_batch_fails
    @ops.app_out["ios"] = ->(_lines) { "[batch] Connected; RX value_handle bound\n" }
    r = run_darwin_only
    assert_equal "iPhone batch", darwin_failed(r)["name"]
    assert_match(/\[batch\] end/, darwin_failed(r)["detail"])
  end

  def test_an_iphone_busy_in_the_hand_off_fails_it
    runs = 0
    @ops.app_out["ios"] = lambda do |_lines|
      runs += 1
      next "[batch] #{FakeOps::APP_BUSY}\n[batch] end\n" if runs == 2
      "[batch] Connected; RX value_handle bound\n[batch] OK face=joy\n" \
        "[batch] OK selftest detail=\"<YL_actual:50,PU_actual:29>\\n\"\n[batch] end\n"
    end
    r = run_darwin_only
    assert_equal "hand-off Mac → iPhone → Watch → Mac", darwin_failed(r)["name"]
    assert_match(/iPhone: no "\[batch\] OK face=joy"/, darwin_failed(r)["detail"])
  end

  def test_a_watch_that_does_not_show_smile_in_the_hand_off_fails_it
    runs = 0
    @ops.app_out["watchos"] = lambda do |_lines|
      runs += 1
      next "[batch] OK face=joy\n[batch] end\n" if runs == 2
      "[batch] Connected; RX value_handle bound\n[batch] OK face=joy\n" \
        "[batch] OK selftest detail=\"<YL_actual:50,PU_actual:29>\\n\"\n[batch] end\n"
    end
    r = run_darwin_only
    assert_equal "hand-off Mac → iPhone → Watch → Mac", darwin_failed(r)["name"]
    assert_match(/Watch: no "\[batch\] OK face=smile"/, darwin_failed(r)["detail"])
  end

  def test_a_mac_whose_connects_do_not_grow_fails_the_hand_off
    @ops.cli_out["status"] = "link=held connects=3 releases=0 last_connect_ms=1 hold_ms=10000\n"
    r = run_darwin_only
    assert_equal "hand-off Mac → iPhone → Watch → Mac", darwin_failed(r)["name"]
    assert_match(/Mac connects 3 -> 3/, darwin_failed(r)["detail"])
  end

  def test_a_mac_that_does_not_get_the_robot_back_fails_the_hand_off
    faces = 0
    @ops.cli_out["face"] = lambda do |args, _env|
      faces += 1
      faces == 2 ? [8, FakeOps::BUSY[1]] : @ops.mac_cli("face", args)
    end
    r = run_darwin_only
    assert_equal "hand-off Mac → iPhone → Watch → Mac", darwin_failed(r)["name"]
    assert_match(/the Mac does not get the robot back/, darwin_failed(r)["detail"])
  end

  # --- report -------------------------------------------------------------------

  def test_markdown_lists_pins_deploy_check_timings_and_darwin
    t = checked(rounds: 3)
    t.run_darwin
    md = t.markdown
    assert_match(/\*\*verdict: pass\*\*/, md)
    assert_match(/- stackchan-picoruby `aaaaaaa`/, md)
    assert_match(/- firmware: R2P2-ESP32 `#{FW['R2P2-ESP32'][0, 7]}`, picoruby `#{FW['picoruby'][0, 7]}`, picoruby-ili9342 `6adc482`/, md)
    assert_match(/- darwin: R2P2-darwin `#{LOCK['darwin']['R2P2-darwin'][0, 7]}`/, md)
    assert_match(/## deploy\n\n\| step \| ok \| detail \|\n\|---\|---\|---\|\n\| pin trees \| ok \|/, md)
    assert_match(/\| r2p2:build_flash \| ok \| ok \|/, md)
    assert_match(/## check\n/, md)
    assert_match(/\| series \| median \|/, md)
    assert_match(/\| text \| \d\.\d{3} \|/, md)
    assert_match(/\| servo \| \d\.\d{3} \|/, md)
    assert_match(/\| connect ms \| \d+\.\d{3} \|/, md)
    assert_match(/\| say drb \| \d\.\d{3} \|/, md)
    assert_match(/- サーボが指示どおりに動いた: y/, md)
    assert_match(/\| hand-off Mac → iPhone → Watch → Mac \| ok \| iPhone /, md)
    assert_match(/\| iPhone batch \| ok \| <YL_actual:50,PU_actual:29> \|/, md)
  end

  def test_median
    assert_equal 2, Acceptance::Runner.median([3, 1, 2])
    assert_equal 2.5, Acceptance::Runner.median([4, 1, 2, 3])
    assert_nil Acceptance::Runner.median([])
  end
end
