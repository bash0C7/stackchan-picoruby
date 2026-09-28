# Runs trial/lock.yml on the robot: for each arm, pin every tree to its sha,
# build and flash with that arm's own stackchan-picoruby tooling, boot, drive it
# over BLE from the Mac, time it, and ask the operator what only eyes and ears
# can tell. Everything touching the machine goes through `ops` (Rakefile's
# DeviceTrialOps), so the order, the pins and the pass rules are host-tested.
#
# ops: git(dir, *args) / rake(dir, *tasks, env:, bundle:) -> [ok, output, seconds]
#      cli(root, *args, env:, stdin:) -> [ok, output, seconds, exitstatus]
#      read(path) / exist?(path) / link(target, path) / prompt(question) -> "y" | "n" | nil
#      sleep(seconds) / notice(text) / now -> seconds / tty?
#
# A question nobody answers (no TTY) stays nil; `rake trial:answer` asks it
# afterwards, and the verdict stays "incomplete" until every answer is "y".
require "json"
require_relative "flash_identity"

class DeviceTrial
  class Stop < StandardError; end

  FAULTS = /Guru Meditation|stack overflow|LoadError|cannot load|NameError|task_wdt|abort\(\) was called/
  STORAGE_OFFSET = "0x410000"
  FACES = %w[neutral smile joy surprised sad angry].freeze
  # 19 JIS X 0208 glyphs: Dispatcher::SUBTITLE_MAX_CHARS, all drawn by blit_glyph.
  SUBTITLE = "スタックチャン字幕の描画時間を測ります"
  SAY_TEXT = "こんにちは。スタックチャンです。今日はルビーワールドカンファレンスで、" \
             "マイコンとパソコンとスマートフォンをルビーでひとつなぎにした話をします。"
  MULTICORE_CHUNK = 2046
  BOOT_CAPTURE_S = 25
  BOOT_READY_S = 20
  DETAIL = /<Y[LR]_actual:\d+,PU_actual:\d+>/
  STACK_FLOOR = 1024
  STUB_REPLY = "reply=stub返答:こんにちは"
  VERIFY_TOLERANCE = 3
  HANDOFF_GAP_S = 7
  HANDOFF_UP = { "NS" => "handoff", "STACKCHAN_PORT" => "8797", "STACKCHAN_SIDECAR_PORT" => "8798",
                 "STACKCHAN_LOGDIR" => "/tmp/stackchan-pico-handoff", "STUB" => "1", "ALLOW_BUSY" => "1" }.freeze
  HANDOFF_DOWN = { "NS" => "handoff" }.freeze
  MAC_B = { "STACKCHAN_PORT" => "8797" }.freeze

  attr_reader :report

  def initialize(lock:, root:, ops:, rounds: 8, stamp: "now")
    @lock   = lock
    @root   = root
    @ops    = ops
    @rounds = rounds
    @report = { "stamp" => stamp, "lock" => lock, "pc_vm" => nil, "arms" => {}, "darwin" => nil, "verdict" => "incomplete" }
  end

  def r2p2    = File.join(@root, "vendor", "R2P2-ESP32")
  def picoruby = File.join(r2p2, "components", "picoruby-esp32", "picoruby")
  def repos_dir = File.join(picoruby, "build", "repos", "esp32-picoruby")
  def worktree(name) = File.join(@root, "build", "trial", name)
  def boot_log(name) = File.join(@root, "build", "trial", "#{name}-boot.log")

  # Base first, trial second, in one session: the timings are only compared
  # inside one run (sessions drift 15-25%).
  def run(arm_names = %w[base trial])
    run_pc_vm
    arm_names.each { |name| run_arm(name) }
    @report["verdict"] = verdict
    @report
  rescue Stop
    @report["verdict"] = "fail"
    @report
  end

  def darwin_dir = File.join(@root, "vendor", "R2P2-darwin")
  def darwin_picoruby = File.join(darwin_dir, "vendor", "picoruby")

  def pin_darwin(r)
    lock = @lock.fetch("darwin")
    step(r, "pin R2P2-darwin") { checkout(darwin_dir, lock.fetch("R2P2-darwin")) }
    step(r, "pin R2P2-darwin picoruby") do
      checkout(darwin_picoruby, lock.fetch("picoruby"))
      git!(darwin_picoruby, "submodule", "update", "--init", "--recursive")
      lock.fetch("picoruby")[0, 7]
    end
  end

  def darwin_pins_hold!
    lock = @lock.fetch("darwin")
    head_is!(darwin_dir, lock.fetch("R2P2-darwin"))
    head_is!(darwin_picoruby, lock.fetch("picoruby"))
  end

  def run_pc_vm
    p = @report["pc_vm"] = { "steps" => [] }
    pin_darwin(p)
    step(p, "pc:vm_build") { rake(@root, "pc:vm_build") }
    step(p, "pc:app_bundle") { rake(@root, "pc:app_bundle") }
    step(p, "pin R2P2-darwin holds") { darwin_pins_hold! }
  end

  def run_arm(name)
    arm = @lock.fetch("arms").fetch(name)
    r = @report["arms"][name] = { "steps" => [], "timings" => {}, "human" => {} }
    wt = worktree(name)
    @stub_sidecar = false

    step(r, "pin trees") { prepare(arm, wt) }
    step(r, "pins hold before setup") { verify(arm, wt, aot: false) }
    step(r, "r2p2:setup") { rake(wt, "r2p2:setup") }
    step(r, "pins hold after setup") { verify(arm, wt, aot: true) }
    step(r, "r2p2:build_flash") { rake(wt, "r2p2:build_flash") }
    step(r, "pins hold after build") { verify(arm, wt, aot: true) }
    step(r, "r2p2:wipe_storage") { rake(wt, "r2p2:wipe_storage") }
    step(r, "r2p2:upload_appmrb") { rake(wt, "r2p2:upload_appmrb", env: { "SRC" => arm.fetch("app", "app/application.rb") }) }
    step(r, "boot") { check_boot(arm, name) }
    step(r, "pc:up") { rake(wt, "pc:up") }

    step(r, "torque on") { cli!(wt, "torque", "on") }
    step(r, "face neutral") { cli!(wt, "face", "neutral") }
    step(r, "led") { cli!(wt, "led", "both", "green", "solid") }
    step(r, "servo detail") do
      out = cli!(wt, "servo", "--yaw-left", "50", "--pitch-up", "30", "--time", "500")
      raise Stop, "no detail line in #{out.inspect}" unless out =~ DETAIL
      out[DETAIL]
    end
    if arm["remote"]
      step(r, "remote servo detail") do
        out = cli!(wt, "remote", "servo", "YL=40", "PU=20", "T=500")
        raise Stop, "no detail line in #{out.inspect}" unless out =~ DETAIL
        out[DETAIL]
      end
      step(r, "remote face") do
        out = cli!(wt, "remote", "face", "2")
        raise Stop, "no ACK in #{out.inspect}" unless out.lines.map(&:strip).include?(".")
        "ACK"
      end
    end
    step(r, "say") do
      out = cli!(wt, "say", SAY_TEXT)
      bytes = out[/OK say bytes=(\d+)/, 1]
      raise Stop, "no `OK say bytes=` in #{out.inspect}" unless bytes
      raise Stop, "#{bytes} bytes fit in two chunks; the clip must span more" if bytes.to_i <= MULTICORE_CHUNK * 2
      "#{bytes} bytes"
    end

    measure(r, wt, arm)
    controller(r, wt, arm) if arm["controller"]
    if arm["stack_check"]
      step(r, "stack high-water") do
        out = cli!(wt, "remote", "stack_free")
        free = out[/<stack_free:(\d+)>/, 1]
        raise Stop, "no stack reading in #{out.inspect}" unless free
        raise Stop, "#{free} B free, below #{STACK_FLOOR} B" if free.to_i < STACK_FLOOR
        "#{free} B free"
      end
    end
    ask(r, name, arm)
    step(r, "torque off") { cli!(wt, "torque", "off") }
    restore_sidecar(r, wt)
  rescue Stop => e
    begin
      restore_sidecar(r, wt)
    rescue Stop
      nil
    end
    raise e
  end

  APPS = { "ios" => "iPhone", "watchos" => "Watch" }.freeze
  APP_TRIAL = "connect;face joy;selftest"
  APP_CONNECTED = "[trial] Connected; RX value_handle bound"
  APP_END = "[trial] end"

  def run_darwin
    d = @report["darwin"] = { "steps" => [], "timings" => {} }
    wt = worktree("trial")
    pin_darwin(d)
    APPS.each_key do |platform|
      %W[#{platform}:device:lib #{platform}:gen #{platform}:device:build].each { |t| step(d, t) { rake(wt, t) } }
    end
    step(d, "pin R2P2-darwin holds") { darwin_pins_hold! }
    step(d, "quiet wait") { @quiet = quiet_wait_s(wt, @lock.fetch("arms").fetch("trial")); "#{@quiet} s" }
    APPS.each do |platform, device|
      step(d, "#{device} trial") do
        @ops.sleep(@quiet)
        out, = app_trial!(wt, platform, APP_TRIAL)
        want!(out, APP_CONNECTED, device)
        want!(out, "[trial] OK face=joy", device)
        detail = out.lines.find { |l| l.start_with?("[trial] OK selftest detail=") }.to_s[DETAIL]
        raise Stop, "#{device}: no selftest detail in #{out.inspect}" unless detail
        detail
      end
    end
    step(d, "hand-off Mac → iPhone → Watch → Mac") { apple_hand_off(d, wt) }
    @report["verdict"] = verdict
    d
  rescue Stop
    @report["verdict"] = "fail"
    d
  end

  def app_trial!(wt, platform, lines)
    t0 = @ops.now
    ok, out, = @ops.rake(wt, "#{platform}:device:run",
                         env: { "APP_CONSOLE" => "1", "APP_LAUNCH_ARGS" => "-StackchanTrial \"#{lines}\"" })
    t = @ops.now - t0
    device = APPS.fetch(platform)
    raise Stop, "#{device}: #{platform}:device:run failed:\n#{out.to_s.lines.last(20).join}" unless ok
    want!(out, APP_END, device)
    [out, t]
  end

  def want!(out, line, device)
    return if out.to_s.lines.map(&:strip).include?(line)
    raise Stop, "#{device}: no #{line.inspect} in #{out.inspect}"
  end

  def apple_hand_off(d, wt)
    @ops.sleep(@quiet)
    cli!(wt, "face", "neutral")
    c0 = status(wt)["connects"].to_i
    @ops.sleep(@quiet)
    out, ti = app_trial!(wt, "ios", "face joy")
    want!(out, "[trial] OK face=joy", "iPhone")
    @ops.sleep(@quiet)
    out, tw = app_trial!(wt, "watchos", "face smile")
    want!(out, "[trial] OK face=smile", "Watch")
    @ops.sleep(@quiet)
    tm = face!(wt, "neutral", {}, "the Mac does not get the robot back")
    c1 = status(wt)["connects"].to_i
    raise Stop, "Mac connects #{c0} -> #{c1}; want more than #{c0}" unless c1 > c0
    { "hand-off iPhone" => ti, "hand-off Watch" => tw, "hand-off Mac" => tm }.each { |k, v| (d["timings"][k] ||= []) << v }
    format("iPhone %.2f s, Watch %.2f s, Mac %.2f s", ti, tw, tm)
  end

  def run_touch
    steps = @report["arms"].fetch("trial")["steps"]
    touched = touch_step(worktree("trial"))
    i = steps.index { |s| s["name"] == touched["name"] }
    i ? steps[i] = touched : steps << touched
    @report["verdict"] = verdict
    @report
  end

  # Asks every question the run left unanswered (it ran without a TTY).
  def answer
    @report["arms"].values.each do |part|
      part["human"].each_value { |h| h["answer"] ||= @ops.prompt(h["question"]) }
    end
    @report["verdict"] = verdict
    @report
  end

  def verdict
    arms = @report["arms"].values
    all_steps = [@report["pc_vm"], *arms, @report["darwin"]].compact.flat_map { |a| a["steps"] }
    return "fail" if all_steps.any? { |s| s["ok"] == false }
    return "incomplete" if arms.empty?
    answers = arms.flat_map { |a| a["human"].values.map { |h| h["answer"] } }
    return "fail" if answers.include?("n")
    return "incomplete" unless all_steps.all? { |s| s["ok"] } && answers.all? { |v| v == "y" } && @report["arms"].key?("trial") && @report["darwin"]
    "pass"
  end

  # --- pins -----------------------------------------------------------------

  def prepare(arm, wt)
    sha = arm.fetch("stackchan-picoruby")
    git!(@root, "fetch", "--quiet", "origin", sha)
    if @ops.exist?(wt)
      git!(wt, "checkout", "--quiet", "--detach", sha)
    else
      git!(@root, "worktree", "add", "--detach", wt, sha)
    end
    # The worktree's tooling builds and flashes the shared R2P2-ESP32 tree.
    @ops.link(File.join(@root, "vendor"), File.join(wt, "vendor")) unless @ops.exist?(File.join(wt, "vendor"))
    checkout(r2p2, arm.fetch("R2P2-ESP32"))
    git!(r2p2, "submodule", "update", "--init", "--recursive")
    arm.fetch("repos").each { |name, want| pin_cache(name, want) }
    "stackchan-picoruby #{sha[0, 7]}, R2P2-ESP32 #{arm['R2P2-ESP32'][0, 7]}, #{arm['repos'].size} cached gems"
  end

  # mruby's gem loader clones a missing gem at its branch tip and never pulls
  # an existing one, so each cache is put at its sha before anything builds.
  # A moved checkout keeps its old commit on a keep-<sha> branch.
  def pin_cache(name, want)
    dir = File.join(repos_dir, name)
    if @ops.exist?(dir)
      have = head(dir)
      return if have == want
      @ops.git(dir, "branch", "keep-#{have}", "HEAD") if have
    else
      git!(@root, "init", "--quiet", dir)
      git!(dir, "remote", "add", "origin", "https://github.com/bash0C7/#{name}.git")
    end
    git!(dir, "fetch", "--quiet", "--depth", "1", "origin", want)
    git!(dir, "checkout", "--quiet", "--detach", want)
  end

  def verify(arm, wt, aot:)
    head_is!(wt, arm.fetch("stackchan-picoruby"))
    clean!(wt)
    head_is!(r2p2, arm.fetch("R2P2-ESP32"))
    clean!(r2p2)
    head_is!(picoruby, arm.fetch("picoruby"))
    arm.fetch("repos").each { |name, want| head_is!(File.join(repos_dir, name), want) }
    if aot && arm["aot"]
      arm["aot"].each { |name, want| head_is!(File.join(wt, "build", "aot", name), want) }
    end
    "all pins hold"
  end

  def checkout(dir, sha)
    git!(dir, "fetch", "--quiet", "origin", sha)
    git!(dir, "checkout", "--quiet", "--detach", sha)
    head_is!(dir, sha)
  end

  def head(dir)
    ok, out, = @ops.git(dir, "rev-parse", "HEAD")
    ok ? out.strip : nil
  end

  def head_is!(dir, want)
    have = head(dir)
    raise Stop, "#{dir} is at #{have.inspect}, lock says #{want}" unless have == want
    want[0, 7]
  end

  def clean!(dir)
    out = git!(dir, "status", "--porcelain", "--untracked-files=no")
    raise Stop, "#{dir} has local changes:\n#{out}" unless out.strip.empty?
  end

  # --- device ---------------------------------------------------------------

  def check_boot(arm, name)
    id = FlashIdentity.parse(rake_out(@root, "r2p2:flash_identity"))
    storage = id["partitions"].dig("storage", "offset")
    raise Stop, "flash has storage at #{storage.inspect}, not #{STORAGE_OFFSET}" unless storage == STORAGE_OFFSET
    version = id["app_version"]
    sha = FlashIdentity.sha_of(version)
    unless sha && arm.fetch("R2P2-ESP32").start_with?(sha)
      raise Stop, "flash App version #{version.inspect} is not R2P2-ESP32 #{arm['R2P2-ESP32'][0, 7]}"
    end
    log = boot_log(name)
    rake(worktree(name), "r2p2:reset_and_capture",
         env: { "SERIAL_LOG" => log, "DURATION" => BOOT_CAPTURE_S.to_s })
    text = @ops.read(log).to_s.encode("UTF-8", invalid: :replace, undef: :replace)
    fault = text[FAULTS]
    raise Stop, "boot log shows #{fault.inspect} (#{log})" if fault
    missing = arm.fetch("boot_markers").reject { |m| text.include?(m) }
    raise Stop, "boot log lacks #{missing.inspect} (#{log})" unless missing.empty?
    rake(@root, "r2p2:reset")
    @ops.sleep(BOOT_READY_S)
    "App version #{version}, storage #{storage}, #{arm['boot_markers'].size} markers, no fault"
  end

  # Same session, same order for both arms. Faces are interleaved so drift
  # lands on all of them; the LED rounds are the BLE round trip with no LCD work.
  def measure(r, wt, arm)
    t = r["timings"]
    @rounds.times do
      FACES.each { |f| (t["face #{f}"] ||= []) << timed!(wt, "face", f) }
    end
    @rounds.times { (t["led (floor)"] ||= []) << timed!(wt, "led", "both", "red", "solid") }
    @rounds.times { (t["subtitle 19 glyphs"] ||= []) << timed!(wt, "raw", "<text:#{SUBTITLE}>") }
    @rounds.times { (t["servo text"] ||= []) << timed!(wt, "servo", "--yaw-left", "30", "--pitch-up", "10", "--time", "300") }
    if arm["remote"]
      @rounds.times { (t["servo remote"] ||= []) << timed!(wt, "remote", "servo", "YL=30", "PU=10", "T=300") }
    end
    3.times { (t["say"] ||= []) << timed!(wt, "say", SAY_TEXT) }
    r["steps"] << { "name" => "timings", "ok" => true, "detail" => "#{t.size} series" }
  rescue Stop => e
    r["steps"] << { "name" => "timings", "ok" => false, "detail" => e.message }
    raise
  end

  def ask(r, name, arm)
    questions = [["servo", "サーボが指示どおりに動いた (#{name})"],
                 ["subtitle", "字幕が欠けずに描画された (#{name})"],
                 ["audio", "say の音声が最後まで途切れずに鳴った (#{name})"]]
    questions << ["remote", "remote servo でも同じように動いた (#{name})"] if arm["remote"]
    questions.each { |key, q| r["human"][key] = { "question" => q, "answer" => @ops.prompt(q) } }
  end

  # --- controller -----------------------------------------------------------

  def quiet_wait_s(wt, arm)
    app = File.join(wt, arm.fetch("app", "app/application.rb"))
    release_after = @ops.read(app).to_s[/release_after\s+([\d_]+)/, 1]
    raise Stop, "no `release_after` in #{app}" unless release_after
    hold = status(wt)["hold_ms"].to_s
    raise Stop, "`stackchan status` has no hold_ms" unless hold.match?(/\A\d+\z/)
    (hold.to_i + release_after.delete("_").to_i) / 1000 + 5
  end

  def controller(r, wt, arm)
    step(r, "quiet wait") { @quiet = quiet_wait_s(wt, arm); "#{@quiet} s" }
    step(r, "selftest detail") do
      out = cli!(wt, "selftest")
      raise Stop, "no detail line in #{out.inspect}" unless out =~ DETAIL
      out[DETAIL]
    end
    touched = touch_step(wt)
    r["steps"] << touched
    raise Stop, touched["detail"] if touched["ok"] == false
    step(r, "calibrate") { calibrate(wt) }
    step(r, "chat (sidecar STUB)") do
      rake(wt, "pc:down")
      @stub_sidecar = true
      @ops.sleep(@quiet)
      rake(wt, "pc:up", env: { "STUB" => "1" })
      out = cli!(wt, "chat", "こんにちは").strip
      raise Stop, "want #{STUB_REPLY.inspect}, got #{out.inspect}" unless out == STUB_REPLY
      out
    end
    step(r, "release and reconnect") { release_and_reconnect(r, wt) }
    step(r, "hand-off Mac A → Mac B → Mac A") { hand_off(r, wt) }
  end

  def status(wt)
    out = cli!(wt, "status")
    line = out.lines.find { |l| l.start_with?("link=") }
    raise Stop, "no `link=` line in #{out.inspect}" unless line
    line.split.to_h { |kv| k, v = kv.split("=", 2); [k, v.to_s] }
  end

  def touch_step(wt)
    name = "touch listen"
    return { "name" => name, "ok" => nil, "detail" => "incomplete: no TTY, nobody to touch the head" } unless @ops.tty?
    @ops.notice("touch the back of the head")
    _, out, _, code = @ops.cli(wt, "touch", "listen", "--count", "1", "--timeout", "30")
    zone = out[/touch zone=\d.*/]
    return { "name" => name, "ok" => false, "detail" => "touch listen exit #{code}:\n#{out}" } unless code == 0 && zone
    { "name" => name, "ok" => true, "detail" => zone.strip }
  end

  def calibrate(wt)
    _, out, _, code = @ops.cli(wt, "calibrate", "--no-torque-toggle", "--format", "json", "--samples", "3", stdin: "\n" * 5)
    raise Stop, "calibrate exit #{code}:\n#{out}" unless code == 0
    last = out.lines.map(&:strip).reject(&:empty?).last.to_s
    json = begin
      JSON.parse(last)
    rescue JSON::ParserError
      nil
    end
    raise Stop, "the last line is not a JSON object: #{last.inspect}" unless json.is_a?(Hash)
    yz = json["servo_yaw_zero"]
    pz = json["servo_pitch_zero"]
    raise Stop, "zeros are not Integers: #{last}" unless yz.is_a?(Integer) && pz.is_a?(Integer)
    fv = json["forward_verify"].is_a?(Hash) ? json["forward_verify"] : {}
    deltas = [fv["yaw_delta"], fv["pitch_delta"]]
    unless deltas.all? { |d| d.is_a?(Integer) && d.abs <= VERIFY_TOLERANCE }
      raise Stop, "forward_verify #{fv.inspect} is not within #{VERIFY_TOLERANCE}"
    end
    "yaw_zero #{yz}, pitch_zero #{pz}, verify delta #{deltas.join('/')}"
  end

  def release_and_reconnect(r, wt)
    cli!(wt, "face", "neutral")
    c0 = status(wt)["connects"].to_i
    @ops.sleep(@quiet)
    seen = status(wt)["link"] == "released"
    t = face!(wt, "joy", {}, "face joy after the release failed")
    c1 = status(wt)["connects"].to_i
    raise Stop, "connects #{c0} -> #{c1}, want #{c0 + 1}" unless c1 == c0 + 1
    (r["timings"]["release and reconnect"] ||= []) << t
    format("release seen: %s, reconnect + face %.2f s", seen ? "yes" : "no", t)
  end

  def hand_off(r, wt)
    cli!(wt, "face", "neutral")
    link = status(wt)["link"]
    raise Stop, "Mac A shows link=#{link} before Mac B starts; want held" unless link == "held"
    begin
      rake(wt, "pc:up", env: HANDOFF_UP)
      @ops.sleep(@quiet)
      cli!(wt, "face", "neutral")
      a_done = @ops.now
      gap = @ops.now - a_done
      if gap >= HANDOFF_GAP_S
        raise Stop, format("Mac B's first call starts %.2f s after Mac A's returned; want < %d s", gap, HANDOFF_GAP_S)
      end
      _, out, _, code = @ops.cli(wt, "face", "joy", env: MAC_B)
      raise Stop, "Mac B was not busy: exit #{code}\n#{out}" unless code == 8 && out.include?("busy:")
      link = status(wt)["link"]
      raise Stop, "Mac A shows link=#{link} after Mac B's busy; want held" unless link == "held"
      @ops.sleep(@quiet)
      tb = face!(wt, "joy", MAC_B, "Mac B never connects")
      @ops.sleep(@quiet)
      ta = face!(wt, "neutral", {}, "Mac A does not get the robot back")
    rescue Stop => e
      @ops.rake(wt, "pc:down", env: HANDOFF_DOWN)
      raise e
    end
    rake(wt, "pc:down", env: HANDOFF_DOWN)
    (r["timings"]["hand-off B"] ||= []) << tb
    (r["timings"]["hand-off A"] ||= []) << ta
    format("gap %.2f s, B %.2f s, A %.2f s", gap, tb, ta)
  end

  def face!(wt, face, env, why)
    ok, out, t, code = @ops.cli(wt, "face", face, env: env)
    raise Stop, "#{why}: exit #{code}\n#{out}" unless ok && out.include?("OK face=")
    t
  end

  def restore_sidecar(r, wt)
    return unless @stub_sidecar
    @stub_sidecar = false
    step(r, "pc:up (real sidecar)") do
      rake(wt, "pc:down")
      @ops.sleep(@quiet)
      rake(wt, "pc:up")
    end
  end

  # --- plumbing -------------------------------------------------------------

  def step(r, name)
    detail = yield
    r["steps"] << { "name" => name, "ok" => true, "detail" => detail.to_s }
  rescue Stop => e
    r["steps"] << { "name" => name, "ok" => false, "detail" => e.message }
    raise
  end

  def git!(dir, *args)
    ok, out, = @ops.git(dir, *args)
    raise Stop, "git -C #{dir} #{args.join(' ')} failed:\n#{out}" unless ok
    out
  end

  def rake(dir, *tasks, env: {}, bundle: true)
    rake_out(dir, *tasks, env: env, bundle: bundle)
    "ok"
  end
  
  def rake_out(dir, *tasks, env: {}, bundle: true)
    ok, out, = @ops.rake(dir, *tasks, env: env, bundle: bundle)
    raise Stop, "rake #{tasks.join(' ')} failed in #{dir}:\n#{out.to_s.lines.last(20).join}" unless ok
    out.to_s
  end

  def cli!(wt, *args)
    ok, out, = @ops.cli(wt, *args)
    raise Stop, "stackchan #{args.join(' ')} failed:\n#{out}" unless ok
    out
  end

  def timed!(wt, *args)
    ok, out, seconds = @ops.cli(wt, *args)
    raise Stop, "stackchan #{args.join(' ')} failed while timing:\n#{out}" unless ok
    seconds
  end

  # --- report ---------------------------------------------------------------

  def self.median(xs)
    s = xs.sort
    n = s.size
    return nil if n.zero?
    n.odd? ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2.0
  end

  def mark(s) = s["ok"].nil? ? "incomplete" : (s["ok"] ? "ok" : "FAIL")

  def markdown
    out = +"# Device trial #{@report['stamp']}\n\n**verdict: #{@report['verdict']}**\n\n"
    out << "## Pins\n\n"
    @lock.fetch("arms").each do |name, arm|
      out << "- #{name}: stackchan-picoruby `#{arm['stackchan-picoruby'][0, 7]}`, R2P2-ESP32 `#{arm['R2P2-ESP32'][0, 7]}`, picoruby `#{arm['picoruby'][0, 7]}`, "
      out << arm["repos"].map { |k, v| "#{k} `#{v[0, 7]}`" }.join(", ")
      out << ", " << arm["aot"].map { |k, v| "#{k} `#{v[0, 7]}`" }.join(", ") if arm["aot"]
      out << "\n"
    end
    out << "- darwin: R2P2-darwin `#{@lock.dig('darwin', 'R2P2-darwin').to_s[0, 7]}`\n" if @lock["darwin"]
    if (p = @report["pc_vm"])
      out << "\n## pc_vm\n\n| step | ok | detail |\n|---|---|---|\n"
      p["steps"].each { |s| out << "| #{s['name']} | #{mark(s)} | #{s['detail'].to_s.lines.first.to_s.strip} |\n" }
    end
    @report["arms"].each do |name, r|
      out << "\n## #{name}\n\n| step | ok | detail |\n|---|---|---|\n"
      r["steps"].each { |s| out << "| #{s['name']} | #{mark(s)} | #{s['detail'].to_s.lines.first.to_s.strip} |\n" }
      out << "\n" << r["human"].map { |k, h| "- #{h['question']}: #{h['answer'] || 'unanswered'}" }.join("\n") << "\n" unless r["human"].empty?
    end
    series = @report["arms"].values.flat_map { |r| r["timings"].keys }.uniq
    unless series.empty?
      names = @report["arms"].keys
      out << "\n## Timings (median seconds, CLI round trip, #{@rounds} rounds)\n\n| series | #{names.join(' | ')} |\n|---|#{names.map { '---' }.join('|')}|\n"
      series.each do |s|
        cells = names.map { |n| m = self.class.median(@report["arms"][n]["timings"][s] || []); m ? format("%.3f", m) : "—" }
        out << "| #{s} | #{cells.join(' | ')} |\n"
      end
    end
    if (d = @report["darwin"])
      out << "\n## darwin\n\n| step | ok | detail |\n|---|---|---|\n"
      d["steps"].each { |s| out << "| #{s['name']} | #{mark(s)} | #{s['detail'].to_s.lines.first.to_s.strip} |\n" }
    end
    out
  end
end
