require 'test/unit'
require 'yaml'
require 'json'
require 'device_trial'

class DeviceTrialTest < Test::Unit::TestCase
  ROOT = "/repo"
  LOCK = YAML.safe_load(File.read(File.expand_path("../trial/lock.yml", __dir__)))

  # A machine made of git HEADs: every directory is a checkout at some sha.
  # rake / cli / prompt are scripted; every call is recorded in order.
  class FakeOps
    attr_reader :calls, :heads, :dirty, :submodules, :files, :robot
    attr_accessor :boot_log, :cli_out, :answers, :on_rake, :fail_rake, :tty, :on_now, :app_out, :rake_out

    def initialize
      @calls = []
      @heads = {}
      @dirty = {}
      @exists = {}
      @answers = []
      @cli_out = {}
      @boot_log = {}
      @on_rake = {}
      @fail_rake = {}
      @app_out = {}
      @rake_out = {}
      @fetched = {}
      @submodules = {}
      @files = {}
      @tty = true
      @clock = 0.0
      @robot = { holder: :a, a_link: "held", connects: 1, stub: false }
    end

    def exist?(path) = @exists[path] || @heads.key?(path)

    def link(target, path)
      @calls << [:link, target, path]
      @exists[path] = true
    end

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
      in ["fetch", *, sha] then (@fetched[[dir, sha]] = true; [true, "", 0])
      in ["checkout", *, "--detach", sha] then (@heads[dir] = sha; [true, "", 0])
      in ["worktree", "add", "--detach", wt, sha] then (@heads[wt] = sha; [true, "", 0])
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
      return [false, "boom", 0] if @fail_rake[tasks.first]
      return [true, app_run(tasks.first, env), 0] if tasks.first.end_with?(":device:run")
      mac_rake(tasks.first, env)
      out = @rake_out[tasks.first]
      [true, out ? out.call : "done", 0]
    end

    APP_BUSY = "busy: robot is held by another controller or unreachable"

    def app_run(task, env)
      platform = task.split(":").first
      @clock += 9.5
      lines = env["APP_LAUNCH_ARGS"][/\A-StackchanTrial "(.*)"\z/, 1].split(";")
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
      (out.map { |l| "[trial] #{l}\n" } << "[trial] end\n").join
    end

    def app_take(platform)
      return false if @robot[:holder] && @robot[:holder] != platform.to_sym
      @robot[:holder] = platform.to_sym
      true
    end

    def mac_rake(task, env)
      case [task, env["NS"]]
      in ["pc:up", nil] then @robot.merge!(holder: :a, a_link: "held", connects: 1, stub: env["STUB"] == "1")
      in ["pc:down", nil] then (@robot[:holder] = nil if @robot[:holder] == :a; @robot[:a_link] = "down")
      in ["pc:down", "handoff"] then @robot[:holder] = nil if @robot[:holder] == :b
      else nil
      end
    end

    def cli(root, *args, env: {}, stdin: nil)
      @calls << [:cli, root, args, env, stdin]
      key = args.first == "remote" ? "remote #{args[1]}" : args.first
      key = "B #{key}" if env["STACKCHAN_PORT"] == "8797"
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
        return BUSY if r[:holder] == :b
        r[:connects] += 1 unless r[:a_link] == "held"
        r.merge!(holder: :a, a_link: "held")
        "OK face=#{args[1]}\n"
      when "B face"
        return BUSY if r[:holder] == :a
        r[:holder] = :b
        "OK face=#{args[1]}\n"
      when "selftest" then "OK selftest detail=\"<YL_actual:50,PU_actual:29>\\n\"\n"
      when "touch" then "[touch] listening (Ctrl-C to exit)...\ntouch zone=1 (back)\n"
      when "calibrate" then CALIBRATION
      when "chat" then r[:stub] ? "reply=stub返答:#{args[1]}\n" : "reply=こんにちは！元気だよ\n"
      else "OK"
      end
    end

    def prompt(question)
      @calls << [:prompt, question]
      @answers.shift
    end
  end

  def wt(name) = File.join(ROOT, "build", "trial", name)
  def r2p2 = File.join(ROOT, "vendor", "R2P2-ESP32")
  def picoruby = File.join(r2p2, "components", "picoruby-esp32", "picoruby")
  def cache(name) = File.join(picoruby, "build", "repos", "esp32-picoruby", name)

  def boot(arm, extra = "")
    "segment 1: paddr=001135c0 vaddr=3fc9e600 size\nI (1387) app_init: App version:      0.2.21-30-g#{LOCK['arms'][arm]['R2P2-ESP32'][0, 7]}\n" \
      "#{LOCK['arms'][arm]['boot_markers'].join("\n")}\n#{extra}"
  end
  
  def identity(arm, version: "0.2.21-30-g#{LOCK['arms'][arm]['R2P2-ESP32'][0, 7]}", storage: "0x410000")
    "[flash_identity] partition nvs 0x9000 0x6000\n[flash_identity] partition factory 0x10000 0x400000\n" \
      "[flash_identity] partition storage #{storage} 0x100000\n[flash_identity] app_version #{version}\n[flash_identity] project R2P2-ESP32\n"
  end

  def setup
    @ops = FakeOps.new
    @ops.heads[r2p2] = "0" * 40
    @ops.heads[picoruby] = LOCK["arms"]["base"]["picoruby"]
    LOCK["arms"].each_value { |arm| @ops.submodules[arm["R2P2-ESP32"]] = { picoruby => arm["picoruby"] } }
    @ops.on_rake["r2p2:setup"] = lambda do |dir, _env|
      aot = dir == wt("trial") ? LOCK["arms"]["trial"]["aot"] : {}
      aot.each { |name, sha| @ops.heads[File.join(dir, "build", "aot", name)] = sha }
    end
    @ops.on_rake["r2p2:build_flash"] = ->(dir, _env) { @flashed = File.basename(dir) }
    @ops.rake_out["r2p2:flash_identity"] = -> { identity(@flashed) }
    @ops.on_rake["r2p2:reset_and_capture"] = lambda do |dir, env|
      @ops.boot_log[env["SERIAL_LOG"]] = boot(File.basename(dir))
    end
    @ops.cli_out["servo"] = "servo detail=\"<YL_actual:50,PU_actual:29>\\n\""
    @ops.cli_out["remote servo"] = ".\n<YL_actual:40,PU_actual:19>\n"
    @ops.cli_out["remote face"] = ".\n"
    @ops.cli_out["say"] = "OK say bytes=9000"
    @ops.cli_out["raw"] = "OK raw"
    @ops.cli_out["remote stack_free"] = "<stack_free:2024>\n"
    @ops.answers = %w[y] * 20
    @ops.files[File.join(wt("trial"), "apps/robot/app.rb")] = File.read(File.expand_path("../apps/robot/app.rb", __dir__))
  end

  def trial(rounds: 2) = DeviceTrial.new(lock: LOCK, root: ROOT, ops: @ops, rounds: rounds, stamp: "t")

  def step_names(report, arm) = report["arms"][arm]["steps"].map { |s| s["name"] }
  def failed(report, arm) = report["arms"][arm]["steps"].find { |s| !s["ok"] }

  def test_both_arms_and_darwin_pass
    t = trial
    t.run
    t.run_darwin
    assert_equal "pass", t.report["verdict"]
    assert_include step_names(t.report, "trial"), "remote servo detail"
    assert_not_include step_names(t.report, "base"), "remote servo detail"
  end

  def test_base_finishes_before_trial_starts_and_each_arm_builds_with_its_own_worktree
    trial.run
    rakes = @ops.calls.select { |c| c[0] == :rake }.map { |c| [File.basename(c[1]), c[2]] }
    base_last = rakes.rindex { |d, _| d == "base" }
    trial_first = rakes.index { |d, _| d == "trial" }
    assert_operator base_last, :<, trial_first
    assert_equal %w[r2p2:setup r2p2:build_flash r2p2:wipe_storage r2p2:upload_appmrb r2p2:reset_and_capture pc:up
                    pc:down pc:up pc:up pc:down pc:down pc:up],
                 rakes.select { |d, _| d == "trial" }.map(&:last)
  end

  def upload_src(arm)
    call = @ops.calls.find { |c| c[0] == :rake && c[1] == wt(arm) && c[2] == "r2p2:upload_appmrb" }
    call.last["SRC"]
  end

  def test_an_arm_without_an_app_key_uploads_app_application_rb
    lock = Marshal.load(Marshal.dump(LOCK))
    lock["arms"]["trial"].delete("app")
    DeviceTrial.new(lock: lock, root: ROOT, ops: @ops, rounds: 2, stamp: "t").run(%w[trial])
    assert_equal "app/application.rb", upload_src("trial")
  end

  def test_an_arm_uploads_the_app_its_lock_entry_names
    lock = Marshal.load(Marshal.dump(LOCK))
    lock["arms"]["trial"]["app"] = "apps/robot/app.rb"
    DeviceTrial.new(lock: lock, root: ROOT, ops: @ops, rounds: 2, stamp: "t").run(%w[trial])
    assert_equal "apps/robot/app.rb", upload_src("trial")
  end

  def test_every_tree_is_pinned_before_the_first_build
    trial.run(%w[trial])
    first_rake = @ops.calls.index { |c| c[0] == :rake && c[2] == "r2p2:setup" }
    pins = @ops.calls[0...first_rake].select { |c| c[0] == :git && c[2] == "checkout" }.map { |c| [c[1], c.last] }
    arm = LOCK["arms"]["trial"]
    assert_include pins, [r2p2, arm["R2P2-ESP32"]]
    arm["repos"].each { |name, sha| assert_include pins, [cache(name), sha] }
  end

  def test_the_pc_vm_is_built_once_from_the_pinned_r2p2_darwin_before_the_first_arm_setup
    r = trial.run
    darwin = File.join(ROOT, "vendor", "R2P2-darwin")
    sha = LOCK["darwin"]["R2P2-darwin"]
    vm_builds = @ops.calls.each_index.select { |i| @ops.calls[i][0] == :rake && @ops.calls[i][2] == "pc:vm_build" }
    assert_equal 1, vm_builds.size
    assert_equal ROOT, @ops.calls[vm_builds.first][1]
    pin = @ops.calls.index([:git, darwin, "checkout", "--quiet", "--detach", sha])
    bundle = @ops.calls.index { |c| c[0] == :rake && c[2] == "pc:app_bundle" }
    first_setup = @ops.calls.index { |c| c[0] == :rake && c[2] == "r2p2:setup" }
    assert_operator pin, :<, vm_builds.first
    assert_operator vm_builds.first, :<, bundle
    assert_operator bundle, :<, first_setup
    assert_equal 1, @ops.calls.count { |c| c[0] == :rake && c[2] == "pc:app_bundle" }
    assert_equal ["pin R2P2-darwin", "pin R2P2-darwin picoruby", "pc:vm_build", "pc:app_bundle", "pin R2P2-darwin holds"],
                 r["pc_vm"]["steps"].map { |s| s["name"] }
  end

  def test_a_failing_pc_vm_build_fails_the_verdict_before_any_arm
    @ops.fail_rake["pc:vm_build"] = true
    r = trial.run
    assert_equal "fail", r["verdict"]
    assert_equal "pc:vm_build", r["pc_vm"]["steps"].find { |s| !s["ok"] }["name"]
    assert_empty r["arms"]
  end

  def test_a_moved_cache_keeps_its_old_commit_on_a_branch
    @ops.heads[cache("picoruby-ili9342")] = "f" * 40
    trial.run(%w[trial])
    assert_include @ops.calls, [:git, cache("picoruby-ili9342"), "branch", "keep-#{'f' * 40}", "HEAD"]
    assert_equal LOCK["arms"]["trial"]["repos"]["picoruby-ili9342"], @ops.heads[cache("picoruby-ili9342")]
  end

  def test_a_pin_that_moves_during_the_build_stops_the_run
    @ops.on_rake["r2p2:build_flash"] = ->(_d, _e) { @ops.heads[cache("picoruby-ili9342")] = "e" * 40 }
    r = trial.run
    assert_equal "fail", r["verdict"]
    assert_equal "pins hold after build", failed(r, "base")["name"]
    assert_nil r["arms"]["trial"]
  end

  def test_local_changes_in_r2p2_stop_the_run
    @ops.dirty[r2p2] = " M components/picoruby-esp32/CMakeLists.txt\n"
    r = trial.run
    assert_equal "pins hold before setup", failed(r, "base")["name"]
    assert_match(/local changes/, failed(r, "base")["detail"])
  end

  def test_trial_aot_pins_are_checked_after_setup
    @ops.on_rake["r2p2:setup"] = ->(_d, _e) {}
    r = trial.run(%w[trial])
    assert_equal "pins hold after setup", failed(r, "trial")["name"]
  end

  def test_a_fault_in_the_boot_log_fails_the_arm
    @ops.on_rake["r2p2:reset_and_capture"] = ->(dir, env) { @ops.boot_log[env["SERIAL_LOG"]] = boot(File.basename(dir), "***ERROR*** A stack overflow in task picoruby_task") }
    r = trial.run
    assert_equal "boot", failed(r, "base")["name"]
  end

  def test_a_missing_marker_fails_the_boot
    @ops.on_rake["r2p2:reset_and_capture"] = ->(dir, env) { @ops.boot_log[env["SERIAL_LOG"]] = boot(File.basename(dir)).sub("[boot] step:led-init-ok", "") }
    r = trial.run(%w[trial])
    assert_match(/led-init-ok/, failed(r, "trial")["detail"])
  end

  def test_boot_must_come_from_the_locked_firmware
    @ops.rake_out["r2p2:flash_identity"] = -> { identity("base", version: "0.2.21-30-g2f18720-dirty") }
    r = trial.run(%w[base])
    assert_match(/App version/, failed(r, "base")["detail"])
  end
  
  def test_the_flash_must_put_storage_where_the_tooling_writes
    @ops.rake_out["r2p2:flash_identity"] = -> { identity("base", storage: "0x310000") }
    r = trial.run(%w[base])
    assert_match(/storage at "0x310000"/, failed(r, "base")["detail"])
  end
  
  def test_a_boot_log_that_lost_the_bootloader_lines_to_the_usb_reconnect_still_passes
    r = trial.run(%w[base])
    assert_equal "ok", r["arms"]["base"]["steps"].find { |s| s["name"] == "boot" }.then { |s| s["ok"] ? "ok" : s["detail"] }
  end
  
  def test_the_identity_is_read_off_flash_from_this_tree_before_the_boot_capture
    trial.run(%w[base])
    rakes = @ops.calls.select { |c| c[0] == :rake }.map { |c| [c[1], c[2]] }
    id = rakes.index([ROOT, "r2p2:flash_identity"])
    cap = rakes.index([wt("base"), "r2p2:reset_and_capture"])
    assert_operator rakes.index([wt("base"), "r2p2:upload_appmrb"]), :<, id
    assert_operator id, :<, cap
  end

  def test_remote_servo_must_answer_the_detail_line
    @ops.cli_out["remote servo"] = ".\n"
    r = trial.run(%w[trial])
    assert_equal "remote servo detail", failed(r, "trial")["name"]
  end

  def test_the_trial_arm_reports_the_stack_left_after_every_handler_ran
    r = trial.run(%w[trial])
    step = r["arms"]["trial"]["steps"].find { |s| s["name"] == "stack high-water" }
    assert step["ok"]
    assert_equal "2024 B free", step["detail"]
  end
  
  def test_less_than_a_kilobyte_of_stack_left_stops_the_arm
    @ops.cli_out["remote stack_free"] = "<stack_free:1023>\n"
    r = trial.run(%w[trial])
    assert_equal "stack high-water", failed(r, "trial")["name"]
  end
  
  def test_a_firmware_without_the_stack_reading_stops_the_arm
    @ops.cli_out["remote stack_free"] = "<stack_free:unknown>\n"
    r = trial.run(%w[trial])
    assert_equal "stack high-water", failed(r, "trial")["name"]
  end
  
  def test_an_arm_without_stack_check_does_not_ask_for_it
    r = trial.run(%w[base])
    refute_includes step_names(r, "base"), "stack high-water"
  end
  
  def test_say_must_span_more_than_two_multicore_chunks
    @ops.cli_out["say"] = "OK say bytes=3000"
    r = trial.run(%w[trial])
    assert_equal "say", failed(r, "trial")["name"]
  end

  def test_unanswered_questions_leave_it_incomplete_until_answered
    @ops.answers = []
    t = trial
    t.run
    t.run_darwin
    assert_equal "incomplete", t.report["verdict"]
    @ops.answers = %w[y] * 20
    t.answer
    assert_equal "pass", t.report["verdict"]
  end

  def test_a_no_fails_it
    @ops.answers = %w[y n] + %w[y] * 20
    t = trial
    t.run
    assert_equal "fail", t.report["verdict"]
  end

  APP_ENV = { "APP_CONSOLE" => "1", "APP_LAUNCH_ARGS" => '-StackchanTrial "connect;face joy;selftest"' }.freeze

  def darwin_step(report, name) = report["darwin"]["steps"].find { |s| s["name"] == name }
  def darwin_failed(report) = report["darwin"]["steps"].find { |s| !s["ok"] }

  def run_darwin_only
    t = trial
    t.run_darwin
    t.report
  end

  def test_darwin_builds_both_apps_in_the_trial_worktree_at_the_locked_r2p2_darwin
    run_darwin_only
    builds = @ops.calls.select { |c| c[0] == :rake && !c[2].end_with?(":device:run") }.map { |c| [c[1], c[2]] }
    assert_equal %w[ios:device:lib ios:gen ios:device:build watchos:device:lib watchos:gen watchos:device:build]
                   .map { |t| [wt("trial"), t] }, builds
    assert_equal LOCK["darwin"]["R2P2-darwin"], @ops.heads[File.join(ROOT, "vendor", "R2P2-darwin")]
  end

  def test_each_app_runs_connect_face_and_selftest_once_on_its_console_after_the_builds
    run_darwin_only
    runs = @ops.calls.select { |c| c[0] == :rake && c[2].end_with?(":device:run") }
    assert_equal [["ios:device:run", APP_ENV], ["watchos:device:run", APP_ENV]], runs.first(2).map { |c| [c[2], c[3]] }
    last_build = @ops.calls.rindex { |c| c[0] == :rake && c[2] == "watchos:device:build" }
    assert_operator last_build, :<, @ops.calls.index(runs.first)
  end

  def test_darwin_passes_on_the_machine_answers_alone
    r = run_darwin_only
    assert_equal ["pin R2P2-darwin", "pin R2P2-darwin picoruby", "ios:device:lib", "ios:gen", "ios:device:build", "watchos:device:lib",
                  "watchos:gen", "watchos:device:build", "pin R2P2-darwin holds", "quiet wait", "iPhone trial",
                  "Watch trial", "hand-off Mac → iPhone → Watch → Mac"], r["darwin"]["steps"].map { |s| s["name"] }
    assert r["darwin"]["steps"].all? { |s| s["ok"] }
    assert_equal "<YL_actual:50,PU_actual:29>", darwin_step(r, "iPhone trial")["detail"]
    assert_empty @ops.calls.select { |c| c[0] == :prompt }
    assert_nil r["darwin"]["human"]
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
                  ["ios:device:run", '-StackchanTrial "face joy"'], [:sleep, 30],
                  ["watchos:device:run", '-StackchanTrial "face smile"'], [:sleep, 30],
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
    assert_nil @ops.calls.find { |c| c[0] == :rake && c[2].end_with?(":device:run") }
    assert_equal "fail", r["verdict"]
  end

  def test_an_iphone_that_never_connects_fails_its_trial
    @ops.app_out["ios"] = ->(_lines) { "[trial] busy: robot is held by another controller or unreachable\n[trial] end\n" }
    r = run_darwin_only
    assert_equal "iPhone trial", darwin_failed(r)["name"]
    assert_match(/Connected; RX value_handle bound/, darwin_failed(r)["detail"])
    assert_equal "fail", r["verdict"]
  end

  def test_an_app_whose_face_is_not_ok_fails_its_trial
    @ops.app_out["watchos"] = ->(_lines) { "[trial] Connected; RX value_handle bound\n[trial] error: timeout\n[trial] end\n" }
    r = run_darwin_only
    assert_equal "Watch trial", darwin_failed(r)["name"]
    assert_match(/OK face=joy/, darwin_failed(r)["detail"])
  end

  def test_an_app_without_the_selftest_detail_fails_its_trial
    @ops.app_out["ios"] = lambda do |_lines|
      "[trial] Connected; RX value_handle bound\n[trial] OK face=joy\n[trial] OK selftest detail=nil\n[trial] end\n"
    end
    r = run_darwin_only
    assert_equal "iPhone trial", darwin_failed(r)["name"]
    assert_match(/selftest detail/, darwin_failed(r)["detail"])
  end

  def test_an_app_that_never_ends_its_trial_fails
    @ops.app_out["ios"] = ->(_lines) { "[trial] Connected; RX value_handle bound\n" }
    r = run_darwin_only
    assert_equal "iPhone trial", darwin_failed(r)["name"]
    assert_match(/\[trial\] end/, darwin_failed(r)["detail"])
  end

  def test_an_iphone_busy_in_the_hand_off_fails_it
    runs = 0
    @ops.app_out["ios"] = lambda do |_lines|
      runs += 1
      next "[trial] #{FakeOps::APP_BUSY}\n[trial] end\n" if runs == 2
      "[trial] Connected; RX value_handle bound\n[trial] OK face=joy\n" \
        "[trial] OK selftest detail=\"<YL_actual:50,PU_actual:29>\\n\"\n[trial] end\n"
    end
    r = run_darwin_only
    assert_equal "hand-off Mac → iPhone → Watch → Mac", darwin_failed(r)["name"]
    assert_match(/iPhone: no "\[trial\] OK face=joy"/, darwin_failed(r)["detail"])
  end

  def test_a_watch_that_does_not_show_smile_in_the_hand_off_fails_it
    runs = 0
    @ops.app_out["watchos"] = lambda do |_lines|
      runs += 1
      next "[trial] OK face=joy\n[trial] end\n" if runs == 2
      "[trial] Connected; RX value_handle bound\n[trial] OK face=joy\n" \
        "[trial] OK selftest detail=\"<YL_actual:50,PU_actual:29>\\n\"\n[trial] end\n"
    end
    r = run_darwin_only
    assert_equal "hand-off Mac → iPhone → Watch → Mac", darwin_failed(r)["name"]
    assert_match(/Watch: no "\[trial\] OK face=smile"/, darwin_failed(r)["detail"])
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
      faces == 2 ? [8, "#{FakeOps::BUSY[1]}"] : @ops.mac_cli("face", args)
    end
    r = run_darwin_only
    assert_equal "hand-off Mac → iPhone → Watch → Mac", darwin_failed(r)["name"]
    assert_match(/the Mac does not get the robot back/, darwin_failed(r)["detail"])
  end

  def test_darwin_markdown_lists_its_steps
    t = trial
    t.run
    t.run_darwin
    assert_match(/\| hand-off Mac → iPhone → Watch → Mac \| ok \| iPhone /, t.markdown)
    assert_match(/\| iPhone trial \| ok \| <YL_actual:50,PU_actual:29> \|/, t.markdown)
  end

  def test_markdown_puts_both_arms_side_by_side
    t = trial(rounds: 3)
    t.run
    md = t.markdown
    assert_match(/\| series \| base \| trial \|/, md)
    assert_match(/\| subtitle 19 glyphs \| \d\.\d{3} \| \d\.\d{3} \|/, md)
    assert_match(/\| servo remote \| — \| \d\.\d{3} \|/, md)
    assert_match(/\| hand-off B \| — \| \d\.\d{3} \|/, md)
    assert_equal 3, t.report["arms"]["trial"]["timings"]["face joy"].size
  end

  CONTROLLER_STEPS = ["quiet wait", "selftest detail", "touch listen", "calibrate", "chat (sidecar STUB)",
                      "release and reconnect", "hand-off Mac A → Mac B → Mac A"].freeze
  HANDOFF_UP = { "NS" => "handoff", "STACKCHAN_PORT" => "8797", "STACKCHAN_SIDECAR_PORT" => "8798",
                 "STACKCHAN_LOGDIR" => "/tmp/stackchan-pico-handoff", "STUB" => "1", "ALLOW_BUSY" => "1" }.freeze
  B = { "STACKCHAN_PORT" => "8797" }.freeze

  def step(report, arm, name) = report["arms"][arm]["steps"].find { |s| s["name"] == name }
  def index_of(&blk) = @ops.calls.index(&blk)
  def cli_call?(c, *args, env: {}) = c[0] == :cli && c[2] == args && c[3] == env
  def rake_call?(c, task, env) = c[0] == :rake && c[2] == task && c[3] == env

  def status_override(nth, link)
    seen = 0
    @ops.cli_out["status"] = lambda do |_args, _env|
      seen += 1
      line = @ops.status_line
      seen == nth ? line.sub(/link=\S+/, "link=#{link}") : line
    end
  end

  def test_the_controller_steps_run_in_order_between_measure_and_stack_high_water
    names = step_names(trial.run(%w[trial]), "trial")
    assert_equal CONTROLLER_STEPS, names[names.index("timings") + 1, CONTROLLER_STEPS.size]
    assert_equal "stack high-water", names[names.index("timings") + 1 + CONTROLLER_STEPS.size]
  end

  def test_every_controller_step_passes_with_its_machine_answer
    r = trial.run(%w[trial])
    assert_equal [], r["arms"]["trial"]["steps"].reject { |s| s["ok"] }
    assert_equal "30 s", step(r, "trial", "quiet wait")["detail"]
    assert_equal "<YL_actual:50,PU_actual:29>", step(r, "trial", "selftest detail")["detail"]
    assert_equal "touch zone=1 (back)", step(r, "trial", "touch listen")["detail"]
    assert_equal "yaw_zero 2048, pitch_zero 2050, verify delta 1/-2", step(r, "trial", "calibrate")["detail"]
    assert_equal "reply=stub返答:こんにちは", step(r, "trial", "chat (sidecar STUB)")["detail"]
    assert_match(/\Arelease seen: yes, reconnect \+ face \d\.\d\d s\z/, step(r, "trial", "release and reconnect")["detail"])
    assert_match(/\Agap \d\.\d\d s, B \d\.\d\d s, A \d\.\d\d s\z/, step(r, "trial", "hand-off Mac A → Mac B → Mac A")["detail"])
    %w[release\ and\ reconnect hand-off\ B hand-off\ A].each { |k| assert_equal 1, r["arms"]["trial"]["timings"][k].size }
  end

  def test_quiet_wait_is_hold_plus_release_after_plus_five_seconds
    assert_equal 30, trial.quiet_wait_s(wt("trial"), LOCK["arms"]["trial"])
    trial.run(%w[trial])
    assert_equal [30], @ops.calls.select { |c| c[0] == :sleep && c != [:sleep, DeviceTrial::BOOT_READY_S] }.map(&:last).uniq
  end

  def test_quiet_wait_follows_the_arm_app_and_the_status_line
    @ops.files[File.join(wt("trial"), "apps/robot/app.rb")] = "StackChan.robot do |bot|\n  bot.release_after 4_000\nend.run\n"
    @ops.cli_out["status"] = "link=held connects=1 releases=0 last_connect_ms=1 hold_ms=3000\n"
    assert_equal 12, trial.quiet_wait_s(wt("trial"), LOCK["arms"]["trial"])
  end

  def test_an_app_without_release_after_stops_the_arm
    @ops.files[File.join(wt("trial"), "apps/robot/app.rb")] = "StackChan.robot do |bot|\nend.run\n"
    r = trial.run(%w[trial])
    assert_equal "quiet wait", failed(r, "trial")["name"]
  end

  def test_the_base_arm_calls_none_of_the_controller_steps
    r = trial.run(%w[base])
    assert_empty step_names(r, "base") & CONTROLLER_STEPS
    verbs = @ops.calls.select { |c| c[0] == :cli }.map { |c| c[2].first }.uniq
    assert_empty verbs & %w[status selftest touch calibrate chat]
    assert_empty @ops.calls.select { |c| %i[sleep notice now].include?(c[0]) && c != [:sleep, DeviceTrial::BOOT_READY_S] }
    assert_equal ["pc:up"], @ops.calls.select { |c| c[0] == :rake && c[1] == wt("base") && c[2].start_with?("pc:") }.map { |c| c[2] }
  end

  def test_touch_asks_the_operator_then_listens_for_one_touch
    trial.run(%w[trial])
    notice = index_of { |c| c == [:notice, "touch the back of the head"] }
    listen = index_of { |c| cli_call?(c, "touch", "listen", "--count", "1", "--timeout", "30") }
    assert_operator notice, :<, listen
    assert_operator listen, :<, index_of { |c| cli_call?(c, "remote", "stack_free") }
  end

  def test_touch_that_times_out_stops_the_arm
    @ops.cli_out["touch"] = [1, "[touch] listening (Ctrl-C to exit)...\n[touch] timed out\n"]
    r = trial.run(%w[trial])
    assert_equal "touch listen", failed(r, "trial")["name"]
    assert_match(/exit 1/, failed(r, "trial")["detail"])
  end

def test_selftest_without_a_detail_line_stops_the_arm
  @ops.cli_out["selftest"] = "OK selftest\n"
  r = trial.run(%w[trial])
  assert_equal "selftest detail", failed(r, "trial")["name"]
end

def run_without_a_tty
  @ops.tty = false
  t = trial
  t.run
  t.run_darwin
  assert_equal "incomplete", t.report["verdict"]
  later = trial
  later.report.merge!(JSON.parse(JSON.generate(t.report)))
  later
end

def touch_steps(report) = report["arms"]["trial"]["steps"].select { |s| s["name"] == "touch listen" }

def test_trial_touch_listens_on_the_trial_arm_and_completes_the_verdict
  later = run_without_a_tty
  @ops.tty = true
  @ops.calls.clear
  later.run_touch
  assert_equal [[:notice, "touch the back of the head"],
                [:cli, wt("trial"), %w[touch listen --count 1 --timeout 30], {}, nil]], @ops.calls
  assert_equal [{ "name" => "touch listen", "ok" => true, "detail" => "touch zone=1 (back)" }], touch_steps(later.report)
  assert_equal "pass", later.report["verdict"]
  assert_match(/\| touch listen \| ok \| touch zone=1 \(back\) \|/, later.markdown)
end

def test_trial_touch_that_times_out_fails_the_verdict
  later = run_without_a_tty
  @ops.tty = true
  @ops.cli_out["touch"] = [1, "[touch] listening (Ctrl-C to exit)...\n[touch] timed out\n"]
  later.run_touch
  steps = touch_steps(later.report)
  assert_equal 1, steps.size
  assert_equal false, steps.first["ok"]
  assert_match(/exit 1/, steps.first["detail"])
  assert_equal "fail", later.report["verdict"]
end

def test_trial_touch_without_a_tty_leaves_it_incomplete
  later = run_without_a_tty
  @ops.calls.clear
  later.run_touch
  assert_empty @ops.calls.select { |c| c[0] == :cli }
  assert_nil touch_steps(later.report).first["ok"]
  assert_equal "incomplete", later.report["verdict"]
end

  def test_touch_without_a_tty_is_incomplete_and_the_arm_goes_on
    @ops.tty = false
    t = trial
    t.run
    t.run_darwin
    s = step(t.report, "trial", "touch listen")
    assert_nil s["ok"]
    assert_match(/incomplete/, s["detail"])
    assert_nil index_of { |c| c[0] == :cli && c[2].first == "touch" }
    assert_include step_names(t.report, "trial"), "stack high-water"
    assert_equal "incomplete", t.report["verdict"]
    assert_match(/\| touch listen \| incomplete \|/, t.markdown)
  end

  def test_calibrate_feeds_five_enters_and_reads_the_json_line
    trial.run(%w[trial])
    c = @ops.calls.find { |x| x[0] == :cli && x[2].first == "calibrate" }
    assert_equal %w[calibrate --no-torque-toggle --format json --samples 3], c[2]
    assert_equal "\n" * 5, c[4]
  end

  def test_calibrate_that_needs_manual_calibration_stops_the_arm
    @ops.cli_out["calibrate"] = [6, "[FAIL] device returned unknown raw position (manual calibration needed)\n"]
    r = trial.run(%w[trial])
    assert_equal "calibrate", failed(r, "trial")["name"]
    assert_match(/exit 6/, failed(r, "trial")["detail"])
  end

  def test_calibrate_whose_last_line_is_not_json_stops_the_arm
    @ops.cli_out["calibrate"] = "[6/6] Re-align FORWARD\n[WARN] verify delta exceeded 3; review before paste.\n"
    r = trial.run(%w[trial])
    assert_equal "calibrate", failed(r, "trial")["name"]
  end

  def test_calibrate_with_a_forward_verify_delta_over_three_stops_the_arm
    @ops.cli_out["calibrate"] = FakeOps::CALIBRATION.sub('"pitch_delta":-2', '"pitch_delta":-4')
    r = trial.run(%w[trial])
    assert_equal "calibrate", failed(r, "trial")["name"]
  end

  def test_chat_restarts_the_mac_on_the_stub_sidecar_after_the_robot_released_it
    trial.run(%w[trial])
    down = index_of { |c| rake_call?(c, "pc:down", {}) }
    wait = index_of { |c| c == [:sleep, 30] }
    up = index_of { |c| rake_call?(c, "pc:up", { "STUB" => "1" }) }
    chat = index_of { |c| cli_call?(c, "chat", "こんにちは") }
    assert_equal [down, wait, up, chat], [down, wait, up, chat].sort
  end

  def test_a_wrong_reply_stops_the_arm
    @ops.cli_out["chat"] = "reply=こんにちは！元気だよ\n"
    r = trial.run(%w[trial])
    assert_equal "chat (sidecar STUB)", failed(r, "trial")["name"]
    assert_match(/reply=/, failed(r, "trial")["detail"])
  end

  def restore_calls
    last_chat = @ops.calls.rindex { |c| c[0] == :cli && c[2].first == "chat" }
    @ops.calls[last_chat..].select { |c| c[0] == :rake || c[0] == :sleep }.last(3)
  end

  def test_the_arm_leaves_the_mac_on_the_real_sidecar
    trial.run(%w[trial])
    torque_off = @ops.calls.rindex { |c| cli_call?(c, "torque", "off") }
    assert_equal [[:rake, wt("trial"), "pc:down", {}], [:sleep, 30], [:rake, wt("trial"), "pc:up", {}]],
                 @ops.calls[torque_off + 1..]
  end

  def test_a_failure_after_chat_still_leaves_the_mac_on_the_real_sidecar
    @ops.cli_out["B face"] = [1, "error: timeout\n"]
    r = trial.run(%w[trial])
    assert_equal "fail", r["verdict"]
    assert_equal [[:rake, wt("trial"), "pc:down", {}], [:sleep, 30], [:rake, wt("trial"), "pc:up", {}]], restore_calls
  end

  def test_release_is_seen_and_the_next_face_reconnects_once
    trial.run(%w[trial])
    chat = index_of { |c| cli_call?(c, "chat", "こんにちは") }
    joy = chat + @ops.calls[chat..].index { |c| cli_call?(c, "face", "joy") }
    assert_equal [:sleep, 30], @ops.calls[joy - 2]
    assert cli_call?(@ops.calls[joy - 1], "status")
  end

  def test_connects_that_do_not_grow_stop_the_arm
    @ops.cli_out["status"] = "link=held connects=1 releases=0 last_connect_ms=1 hold_ms=10000\n"
    r = trial.run(%w[trial])
    assert_equal "release and reconnect", failed(r, "trial")["name"]
    assert_match(/connects/, failed(r, "trial")["detail"])
  end

  def test_hand_off_starts_mac_b_on_its_own_namespace_ports_and_log_dir
    trial.run(%w[trial])
    assert index_of { |c| rake_call?(c, "pc:up", HANDOFF_UP) }
    b_calls = @ops.calls.select { |c| c[0] == :cli && c[3] == B }.map { |c| c[2] }
    assert_equal [%w[face joy], %w[face joy]], b_calls
  end

  def test_hand_off_order
    trial.run(%w[trial])
    up = index_of { |c| rake_call?(c, "pc:up", HANDOFF_UP) }
    seq = @ops.calls[up - 2..].reject { |c| c[0] == :now }.first(12).map { |c| c[0] == :cli ? [c[2], c[3]] : c[0..2] + (c[0] == :rake ? [c[3]] : []) }
    assert_equal [[%w[face neutral], {}], [%w[status], {}],
                  [:rake, wt("trial"), "pc:up", HANDOFF_UP], [:sleep, 30],
                  [%w[face neutral], {}], [%w[face joy], B], [%w[status], {}], [:sleep, 30],
                  [%w[face joy], B], [:sleep, 30], [%w[face neutral], {}],
                  [:rake, wt("trial"), "pc:down", { "NS" => "handoff" }]], seq
  end

  def test_mac_b_that_is_not_busy_stops_the_arm_and_mac_b_is_stopped
    @ops.cli_out["B face"] = [1, "error: timeout\n"]
    r = trial.run(%w[trial])
    assert_equal "hand-off Mac A → Mac B → Mac A", failed(r, "trial")["name"]
    assert_match(/busy/, failed(r, "trial")["detail"])
    assert index_of { |c| rake_call?(c, "pc:down", { "NS" => "handoff" }) }
  end

  def test_mac_a_not_holding_before_mac_b_starts_stops_the_arm
    status_override(5, "released")
    r = trial.run(%w[trial])
    assert_equal "hand-off Mac A → Mac B → Mac A", failed(r, "trial")["name"]
    assert_match(/before/, failed(r, "trial")["detail"])
    assert_nil index_of { |c| rake_call?(c, "pc:up", HANDOFF_UP) }
  end

  def test_mac_a_losing_the_robot_at_mac_b_busy_stops_the_arm
    status_override(6, "released")
    r = trial.run(%w[trial])
    assert_equal "hand-off Mac A → Mac B → Mac A", failed(r, "trial")["name"]
    assert_match(/after/, failed(r, "trial")["detail"])
    assert index_of { |c| rake_call?(c, "pc:down", { "NS" => "handoff" }) }
  end

  def test_mac_b_starting_seven_seconds_after_mac_a_stops_the_arm
    @ops.on_now = ->(calls) { calls.last(2) == [[:now], [:now]] ? 7.0 : 0 }
    r = trial.run(%w[trial])
    assert_equal "hand-off Mac A → Mac B → Mac A", failed(r, "trial")["name"]
    assert_match(/7\.00 s/, failed(r, "trial")["detail"])
    assert_empty @ops.calls.select { |c| c[0] == :cli && c[3] == B }
    assert index_of { |c| rake_call?(c, "pc:down", { "NS" => "handoff" }) }
  end

  def test_mac_b_that_never_connects_stops_the_arm
    @ops.cli_out["B face"] = FakeOps::BUSY
    r = trial.run(%w[trial])
    assert_equal "hand-off Mac A → Mac B → Mac A", failed(r, "trial")["name"]
    assert_match(/B never connects/, failed(r, "trial")["detail"])
  end

  def test_mac_a_that_does_not_get_the_robot_back_stops_the_arm
    @ops.cli_out["face"] = ->(args, _env) { @ops.calls.any? { |c| c[0] == :cli && c[3] == B } ? [1, "error: timeout\n"] : @ops.mac_cli("face", args) }
    r = trial.run(%w[trial])
    assert_equal "hand-off Mac A → Mac B → Mac A", failed(r, "trial")["name"]
    assert_match(/A/, failed(r, "trial")["detail"])
  end

  def test_median
    assert_equal 2, DeviceTrial.median([3, 1, 2])
    assert_equal 2.5, DeviceTrial.median([4, 1, 2, 3])
    assert_nil DeviceTrial.median([])
  end

  def darwin_picoruby = File.join(ROOT, "vendor", "R2P2-darwin", "vendor", "picoruby")

  def test_the_mac_vm_builds_on_the_locked_darwin_picoruby
    r = trial.run(%w[base])
    assert_include r["pc_vm"]["steps"].map { |s| s["name"] }, "pin R2P2-darwin picoruby"
    assert_equal LOCK["darwin"]["picoruby"], @ops.heads[darwin_picoruby]
    pin = @ops.calls.index { |c| c[0] == :git && c[1] == darwin_picoruby && c[2] == "checkout" }
    build = @ops.calls.index { |c| c[0] == :rake && c[2] == "pc:vm_build" }
    assert_operator pin, :<, build
  end

  def test_a_darwin_picoruby_moved_during_the_build_fails_the_pin_check
    @ops.on_rake["pc:vm_build"] = ->(_d, _e) { @ops.heads[darwin_picoruby] = "0" * 40 }
    r = trial.run(%w[base])
    assert_equal "fail", r["verdict"]
    assert_match(/picoruby is at "0{40}"/, r["pc_vm"]["steps"].find { |s| !s["ok"] }["detail"])
  end

  def test_the_board_is_reset_out_of_the_capture_s_download_mode_and_given_time_to_advertise_before_pc_up
    trial.run(%w[base])
    seq = @ops.calls.filter_map do |c|
      case c
      in [:rake, dir, "r2p2:reset_and_capture", *] then :capture if dir == wt("base")
      in [:rake, ROOT, "r2p2:reset", *] then :reset
      in [:sleep, DeviceTrial::BOOT_READY_S] then :ready
      in [:rake, dir, "pc:up", *] then :up if dir == wt("base")
      else nil
      end
    end
    assert_equal %i[capture reset ready up], seq.first(4)
  end
end
