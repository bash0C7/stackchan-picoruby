# Runs trial/lock.yml on the robot: for each arm, pin every tree to its sha,
# build and flash with that arm's own stackchan-picoruby tooling, boot, drive it
# over BLE from the Mac, time it, and ask the operator what only eyes and ears
# can tell. Everything touching the machine goes through `ops` (Rakefile's
# DeviceTrialOps), so the order, the pins and the pass rules are host-tested.
#
# ops: git(dir, *args) / rake(dir, *tasks, env:, bundle:) / cli(root, *args) -> [ok, output, seconds]
#      read(path) / exist?(path) / link(target, path) / prompt(question) -> "y" | "n" | nil
#
# A question nobody answers (no TTY) stays nil; `rake trial:answer` asks it
# afterwards, and the verdict stays "incomplete" until every answer is "y".
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
  DETAIL = /<Y[LR]_actual:\d+,PU_actual:\d+>/

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

  def run_pc_vm
    p = @report["pc_vm"] = { "steps" => [] }
    sha = @lock.fetch("darwin").fetch("R2P2-darwin")
    step(p, "pin R2P2-darwin") { checkout(darwin_dir, sha) }
    step(p, "pc:vm_build") { rake(@root, "pc:vm_build") }
    step(p, "pc:app_bundle") { rake(@root, "pc:app_bundle") }
    step(p, "pin R2P2-darwin holds") { head_is!(darwin_dir, sha) }
  end

  def run_arm(name)
    arm = @lock.fetch("arms").fetch(name)
    r = @report["arms"][name] = { "steps" => [], "timings" => {}, "human" => {} }
    wt = worktree(name)

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
    ask(r, name, arm)
    step(r, "torque off") { cli!(wt, "torque", "off") }
  end

  # iOS and watchOS against the trial arm's firmware: device builds of the
  # stackchan apps at the locked R2P2-darwin, with picoruby-drb-ble from the
  # trial worktree, then the operator runs them.
  def run_darwin
    d = @report["darwin"] = { "steps" => [], "human" => {} }
    sha = @lock.fetch("darwin").fetch("R2P2-darwin")
    dir = File.join(@root, "vendor", "R2P2-darwin")
    gemdir = File.join(worktree("trial"), "mrbgems", "picoruby-drb-ble")
    step(d, "pin R2P2-darwin") { checkout(dir, sha) }
    env = { "STACKCHAN_DRB_BLE_GEMDIR" => gemdir }
    %w[ios:stackchan:device:lib ios:stackchan:gen ios:stackchan:device:build ios:stackchan:device:run
       watchos:stackchan:device:lib watchos:stackchan:gen watchos:stackchan:device:build watchos:stackchan:device:run].each do |t|
      step(d, t) { rake(dir, t, env: env, bundle: false) }
    end
    step(d, "pin R2P2-darwin holds") { head_is!(dir, sha) }
    [["iphone_drb", "iPhone: Connect の後に 'dRuby over BLE: on' が出て、face joy で顔が変わった"],
     ["watch_drb",  "Apple Watch: Connect の後に Face で顔が変わり、ぐるっとで首が回った"]].each do |key, q|
      d["human"][key] = { "question" => q, "answer" => @ops.prompt(q) }
    end
    @report["verdict"] = verdict
    d
  rescue Stop
    @report["verdict"] = "fail"
    d
  end

  # Asks every question the run left unanswered (it ran without a TTY).
  def answer
    (@report["arms"].values + [@report["darwin"]].compact).each do |part|
      part["human"].each_value { |h| h["answer"] ||= @ops.prompt(h["question"]) }
    end
    @report["verdict"] = verdict
    @report
  end

  def verdict
    arms = @report["arms"].values
    all_steps = [@report["pc_vm"], *arms, @report["darwin"]].compact.flat_map { |a| a["steps"] }
    return "fail" unless all_steps.all? { |s| s["ok"] }
    return "incomplete" if arms.empty?
    answers = (arms + [@report["darwin"]].compact).flat_map { |a| a["human"].values.map { |h| h["answer"] } }
    return "fail" if answers.include?("n")
    return "incomplete" unless answers.all? { |v| v == "y" } && @report["arms"].key?("trial") && @report["darwin"]
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
    log = boot_log(name)
    rake(worktree(name), "r2p2:reset_and_capture",
         env: { "SERIAL_LOG" => log, "DURATION" => BOOT_CAPTURE_S.to_s })
    text = @ops.read(log).to_s.encode("UTF-8", invalid: :replace, undef: :replace)
    fault = text[FAULTS]
    raise Stop, "boot log shows #{fault.inspect} (#{log})" if fault
    raise Stop, "boot log has no storage offset #{STORAGE_OFFSET} (#{log})" unless text.include?(STORAGE_OFFSET)
    missing = arm.fetch("boot_markers").reject { |m| text.include?(m) }
    raise Stop, "boot log lacks #{missing.inspect} (#{log})" unless missing.empty?
    version = text[/App version:\s*(\S+)/, 1]
    unless version && version.size >= 7 && arm.fetch("R2P2-ESP32").start_with?(version)
      raise Stop, "App version #{version.inspect} is not R2P2-ESP32 #{arm['R2P2-ESP32'][0, 7]} (#{log})"
    end
    "App version #{version}, #{arm['boot_markers'].size} markers, no fault"
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
    ok, out, = @ops.rake(dir, *tasks, env: env, bundle: bundle)
    raise Stop, "rake #{tasks.join(' ')} failed in #{dir}:\n#{out.to_s.lines.last(20).join}" unless ok
    "ok"
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
      p["steps"].each { |s| out << "| #{s['name']} | #{s['ok'] ? 'ok' : 'FAIL'} | #{s['detail'].to_s.lines.first.to_s.strip} |\n" }
    end
    @report["arms"].each do |name, r|
      out << "\n## #{name}\n\n| step | ok | detail |\n|---|---|---|\n"
      r["steps"].each { |s| out << "| #{s['name']} | #{s['ok'] ? 'ok' : 'FAIL'} | #{s['detail'].to_s.lines.first.to_s.strip} |\n" }
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
      d["steps"].each { |s| out << "| #{s['name']} | #{s['ok'] ? 'ok' : 'FAIL'} | #{s['detail'].to_s.lines.first.to_s.strip} |\n" }
      out << "\n" << d["human"].map { |k, h| "- #{h['question']}: #{h['answer'] || 'unanswered'}" }.join("\n") << "\n"
    end
    out
  end
end
