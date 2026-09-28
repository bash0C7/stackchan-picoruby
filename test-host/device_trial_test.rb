require 'test/unit'
require 'yaml'
require 'device_trial'

class DeviceTrialTest < Test::Unit::TestCase
  ROOT = "/repo"
  LOCK = YAML.safe_load(File.read(File.expand_path("../trial/lock.yml", __dir__)))

  # A machine made of git HEADs: every directory is a checkout at some sha.
  # rake / cli / prompt are scripted; every call is recorded in order.
  class FakeOps
    attr_reader :calls, :heads, :dirty, :submodules
    attr_accessor :boot_log, :cli_out, :answers, :on_rake, :fail_rake

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
      @fetched = {}
      @submodules = {}
    end

    def exist?(path) = @exists[path] || @heads.key?(path)

    def link(target, path)
      @calls << [:link, target, path]
      @exists[path] = true
    end

    def read(path) = @boot_log[path]

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
      [true, "done", 0]
    end

    def cli(root, *args)
      @calls << [:cli, root, *args]
      out = @cli_out.fetch(args.first) { |k| k == "remote" ? @cli_out.fetch("remote #{args[1]}") : "OK" }
      out = out.call(args) if out.respond_to?(:call)
      [true, out, 0.1 + @calls.size * 0.001]
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
    markers = LOCK["arms"][arm]["boot_markers"].join("\n")
    "I (61) boot: 2 storage Unknown data 01 82 00410000 00100000\n  0x410000\n" \
      "I (95) app_init: App version:      #{LOCK['arms'][arm]['R2P2-ESP32'][0, 7]}\n#{markers}\n#{extra}"
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
    @ops.on_rake["r2p2:reset_and_capture"] = lambda do |dir, env|
      @ops.boot_log[env["SERIAL_LOG"]] = boot(File.basename(dir))
    end
    @ops.cli_out["servo"] = "servo detail=\"<YL_actual:50,PU_actual:29>\\n\""
    @ops.cli_out["remote servo"] = ".\n<YL_actual:40,PU_actual:19>\n"
    @ops.cli_out["remote face"] = ".\n"
    @ops.cli_out["say"] = "OK say bytes=9000"
    @ops.cli_out["raw"] = "OK raw"
    @ops.answers = %w[y] * 20
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
    assert_equal %w[r2p2:setup r2p2:build_flash r2p2:wipe_storage r2p2:upload_appmrb r2p2:reset_and_capture pc:up],
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
    assert_equal ["pin R2P2-darwin", "pc:vm_build", "pc:app_bundle", "pin R2P2-darwin holds"],
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
    @ops.on_rake["r2p2:reset_and_capture"] = ->(dir, env) { @ops.boot_log[env["SERIAL_LOG"]] = boot(File.basename(dir)).sub(/App version:\s*\S+/, "App version: 2f18720-dirty") }
    r = trial.run(%w[base])
    assert_match(/App version/, failed(r, "base")["detail"])
  end

  def test_remote_servo_must_answer_the_detail_line
    @ops.cli_out["remote servo"] = ".\n"
    r = trial.run(%w[trial])
    assert_equal "remote servo detail", failed(r, "trial")["name"]
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

  def test_darwin_builds_against_the_trial_worktree_gem
    t = trial
    t.run
    t.run_darwin
    lib = @ops.calls.find { |c| c[0] == :rake && c[2] == "ios:stackchan:device:lib" }
    assert_equal File.join(wt("trial"), "mrbgems", "picoruby-drb-ble"), lib.last["STACKCHAN_DRB_BLE_GEMDIR"]
    assert_equal LOCK["darwin"]["R2P2-darwin"], @ops.heads[File.join(ROOT, "vendor", "R2P2-darwin")]
  end

  def test_markdown_puts_both_arms_side_by_side
    t = trial(rounds: 3)
    t.run
    md = t.markdown
    assert_match(/\| series \| base \| trial \|/, md)
    assert_match(/\| subtitle 19 glyphs \| \d\.\d{3} \| \d\.\d{3} \|/, md)
    assert_match(/\| servo remote \| — \| \d\.\d{3} \|/, md)
    assert_equal 3, t.report["arms"]["trial"]["timings"]["face joy"].size
  end

  def test_median
    assert_equal 2, DeviceTrial.median([3, 1, 2])
    assert_equal 2.5, DeviceTrial.median([4, 1, 2, 3])
    assert_nil DeviceTrial.median([])
  end
end
