# Runs acceptance/lock.yml on the robot from this checkout. `deploy` pins every tree,
# builds and flashes the firmware (the only firmware write of a report), then
# sends the app; `upload_app` re-sends only the app. `check` reads the flash
# back, boots, drives the robot over BLE from the Mac, times it, and asks the
# operator what only eyes and ears can tell, as often as needed against that
# one deploy. Everything touching the machine goes through `ops` (Rakefile's
# Acceptance::Ops), so the order, the pins and the pass rules are host-tested.
#
# ops: git(dir, *args) / rake(dir, *tasks, env:, bundle:) -> [ok, output, seconds]
#      cli(root, *args, env:, stdin:) -> [ok, output, seconds, exitstatus]
#      read(path) / exist?(path) / prompt(question) -> "y" | "n" | nil
#      sleep(seconds) / notice(text) / now -> seconds / tty?
#
# A question nobody answers (no TTY) stays nil; `rake acceptance:answer` asks it
# afterwards, and the verdict stays "incomplete" until every answer is "y".
require "json"
require "digest"
require_relative "../lib/flash_identity"

# Host-side acceptance run of the robot.
module Acceptance
  # Raised to end the run with a failed step.
  class Stop < StandardError; end
  # Raised by a step that cannot finish without a person; the step is recorded as incomplete.
  class Pending < StandardError; end

  # Runs the deploy, check and darwin phases of acceptance/lock.yml and builds the report.
  class Runner
    # @rbs @bundled: Array[String]
    # @rbs @lock: Hash[String, untyped]
    # @rbs @root: String
    # @rbs @ops: Ops
    # @rbs @rounds: Integer
    # @rbs @may_write: Array[String]
    # @rbs @report: Hash[String, untyped]
    # @rbs @quiet: Integer?

    FAULTS = /Guru Meditation|stack overflow|LoadError|cannot load|NameError|task_wdt|abort\(\) was called/
    STORAGE_OFFSET = "0x410000"
    FACES = %w[neutral smile joy surprised sad angry].freeze
    # 19 JIS X 0208 glyphs: Dispatcher::SUBTITLE_MAX_CHARS, all drawn by blit_glyph.
    SUBTITLE = "スタックチャン字幕の描画時間を測ります"
    SAY_TEXT = "こんにちは"
    MULTICORE_CHUNK = 2046
    BOOT_CAPTURE_S = 25
    DETAIL = /<Y[LR]_actual:\d+,PU_actual:\d+>/
    STACK_FLOOR = 512
    VERIFY_TOLERANCE = 3
    PC_UP_TRIES = 6
    PC_UP_WAIT_S = 5
    RESETS = %w[r2p2:build_flash r2p2:flash_identity r2p2:reset_and_capture r2p2:reset].freeze
    FIRMWARE_WRITES = %w[r2p2:build_flash r2p2:build_flash_appmrb r2p2:flash r2p2:full_rebuild].freeze
    APP_WRITES = %w[r2p2:upload_appmrb r2p2:upload_mrb r2p2:wipe_storage].freeze
    FIRMWARE_INPUTS = %w[build_config/esp32-stackchan.rb aot/kernels aot/mcu-shim aot/multicore.pin aot/suppify.pin
                         tools/aot mrbgems/picoruby-stackchan-protocol].freeze
    QUESTIONS = [["servo", "サーボが指示どおりに動いた"],
                 ["subtitle", "字幕が欠けずに描画された"],
                 ["audio", "say の音声が最後まで途切れずに鳴った"],
                 ["distortion", "say の音声が割れずに鳴った"]].freeze

    attr_reader :report #: Hash[String, untyped]

    # Builds a runner over the lock contents, the checkout root, the ops adapter and the app input paths.
    #: (lock: Hash[String, untyped], root: String, ops: Ops, bundled: Array[String], ?rounds: Integer, ?stamp: String) -> void
    def initialize(lock:, root:, ops:, bundled:, rounds: 8, stamp: "now")
      @bundled = bundled
      @lock   = lock
      @root   = root
      @ops    = ops
      @rounds = rounds
      @may_write = []
      @report = { "stamp" => stamp, "lock" => lock, "root" => nil, "deploy" => nil, "check" => nil,
                  "darwin" => nil, "resets" => 0, "verdict" => "incomplete" }
    end

    # Returns the firmware section of the lock.
    #: () -> Hash[String, untyped]
    def firmware = @lock.fetch("firmware")
    # Returns the R2P2-ESP32 checkout path.
    #: () -> String
    def r2p2    = File.join(@root, "vendor", "R2P2-ESP32")
    # Returns the picoruby checkout path inside R2P2-ESP32.
    #: () -> String
    def picoruby = File.join(r2p2, "components", "picoruby-esp32", "picoruby")
    # Returns the directory of the fetched gem caches.
    #: () -> String
    def repos_dir = File.join(picoruby, "build", "repos", "esp32-picoruby")
    # Returns the boot log path.
    #: () -> String
    def boot_log = File.join(@root, "build", "acceptance", "boot.log")
    # Returns the R2P2-darwin checkout path.
    #: () -> String
    def darwin_dir = File.join(@root, "vendor", "R2P2-darwin")
    # Returns the picoruby checkout path inside R2P2-darwin.
    #: () -> String
    def darwin_picoruby = File.join(darwin_dir, "vendor", "picoruby")

    # Returns the ordered deploy steps as [name, body] pairs.
    #: () -> Array[[String, ^() -> untyped]]
    def deploy_plan
      [["pin trees", -> { pin_trees }],
       ["pins hold before setup", -> { verify(aot: false) }],
       ["r2p2:setup", -> { rake("r2p2:setup") }],
       ["pins hold after setup", -> { verify(aot: true) }],
       ["r2p2:build_flash", -> { rake("r2p2:build_flash") }],
       ["pins hold after build", -> { verify(aot: true) }],
       ["app upload", -> { app_upload }],
       ["flash identity", -> { flash_identity }],
       ["boot", -> { boot }]]
    end

    # Returns the ordered check steps as [name, body] pairs.
    #: () -> Array[[String, ^() -> untyped]]
    def check_plan
      [["flash identity", -> { flash_identity }],
       ["boot", -> { boot }],
       ["pc:up", -> { pc_up }],
       ["torque on", -> { out = cli!("torque", "on"); record_connect_ms; out }],
       ["face neutral", -> { cli!("face", "neutral") }],
       ["led", -> { cli!("led", "both", "green", "solid") }],
       ["servo detail", -> { detail!(cli!("servo", "--yaw-left", "50", "--pitch-up", "30", "--time", "500")) }],
       ["servo health", -> { servo_health }],
       ["say", -> { say }],
       ["timings", -> { measure }],
       ["quiet wait", -> { @quiet = quiet_wait_s; "#{@quiet} s" }],
       ["selftest detail", -> { detail!(cli!("selftest")) }],
       ["touch listen", -> { touch }],
       ["calibrate", -> { calibrate }],
       ["release and reconnect", -> { release_and_reconnect }],
       ["stack high-water", -> { stack_high_water }],
       ["questions", -> { ask }],
       ["torque off", -> { cli!("torque", "off") }],
       ["chat", -> { chat }]]
    end

    # Pins the trees, builds and flashes the firmware, then sends the app. Returns the report. Raises Stop when the report already has a deploy.
    #: () -> Hash[String, untyped]
    def deploy
      raise Stop, "report #{@report['stamp']} already has a deploy; one report is one firmware" if @report["deploy"]
      d = @report["deploy"] = { "lock_digest" => lock_digest, "steps" => [] }
      @report["check"] = { "steps" => [], "timings" => {}, "human" => {} }
      settle do
        @may_write = FIRMWARE_WRITES
        deploy_plan.each { |name, body| step(d, name, &body) }
      ensure
        @may_write = []
      end
    end

    # Re-sends only the app after a finished firmware deploy. Returns the report. Raises Stop when the firmware pins or inputs moved.
    #: () -> Hash[String, untyped]
    def upload_app
      names = deploy_plan.map(&:first)
      at = names.index("app upload")
      d = @report["deploy"]
      firmware_ok = d && d["steps"].first(at).map { |s| s["name"] } == names.first(at) && d["steps"].first(at).all? { |s| s["ok"] }
      raise Stop, "report #{@report['stamp']} has no firmware deploy that finished ok; run acceptance:deploy" unless firmware_ok
      same_tree!(app: false)
      d["steps"].slice!(at..)
      @report["check"] = { "steps" => [], "timings" => {}, "human" => {} }
      settle do
        step(d, "pins hold") { verify(aot: true, root: false) }
        step(d, "qemu gate") { rake("r2p2:qemu_check", env: { "QEMU_PROBE_APP" => firmware.fetch("app") }) }
        deploy_plan.drop(at).each { |name, body| step(d, name, &body) }
      end
    end

    # Uploads the lock's app with app writes allowed and records the commit it came from. Returns "ok".
    #: () -> String
    def app_upload
      allowed = @may_write
      @may_write = allowed + APP_WRITES
      clean!(@root, *app_inputs)
      @report["deploy"]["app_root"] = head(@root)
      rake("r2p2:upload_appmrb", env: { "SRC" => firmware.fetch("app") })
    ensure
      @may_write = allowed
    end

    # Runs the check steps, optionally starting at step from and keeping the earlier steps of the previous check. Returns the report. Raises Stop without a finished deploy.
    #: (?from: String?) -> Hash[String, untyped]
    def check(from: nil)
      raise Stop, "report #{@report['stamp']} has no deploy that finished ok; run acceptance:deploy" unless deployed?
      same_tree!
      plan = check_plan
      names = plan.map(&:first)
      start = from ? names.index(from) : 0
      raise Stop, "no check step #{from.inspect}; steps: #{names.join(', ')}" unless start
      prev = @report["check"] || { "steps" => [], "timings" => {}, "human" => {} }
      kept = names.first(start).map do |name|
        s = prev["steps"].find { |x| x["name"] == name }
        raise Stop, "FROM=#{from} keeps #{name.inspect}, which the previous check did not run" unless s
        raise Stop, "FROM=#{from} keeps #{name.inspect}, which failed: #{s['detail']}" if s["ok"] == false
        s
      end
      c = @report["check"] = { "root" => head(@root), "steps" => kept, "timings" => {},
                               "human" => names.index("questions") < start ? prev["human"] : {} }
      earlier = from ? prev["timings"] : {}
      @quiet = nil
      settle do
        plan.drop(start).each { |name, body| step(c, name, &body) }
      ensure
        c["timings"] = earlier.merge(c["timings"])
      end
    end

    # Returns the SHA-256 of the firmware pins.
    #: () -> String
    def lock_digest = Digest::SHA256.hexdigest(JSON.generate(@lock.fetch("firmware")))

    # Returns the paths whose change alters the app on the board.
    #: () -> Array[String]
    def app_inputs = [firmware.fetch("app"), *@bundled]

    # Raises Stop when the firmware pins or inputs (and the app inputs when app) differ from what the deploy used.
    #: (?app: bool) -> void
    def same_tree!(app: true)
      raise Stop, "the firmware pins in acceptance/lock.yml differ from the ones report #{@report['stamp']} deployed" unless @report["deploy"]["lock_digest"] == lock_digest
      built = @report["root"]
      moved = moved_since(built, FIRMWARE_INPUTS)
      raise Stop, "#{moved.join(', ')} differ from #{built[0, 7]}, which the deploy built; that is another firmware and another report" unless moved.empty?
      return unless app
      sent = @report["deploy"]["app_root"] || built
      moved = moved_since(sent, app_inputs)
      raise Stop, "#{moved.join(', ')} differ from #{sent[0, 7]}, which the board runs; run acceptance:app" unless moved.empty?
    end

    # Returns the paths whose tree at commit differs from HEAD. Raises Stop when the checkout has local changes there.
    #: (String commit, Array[String] paths) -> Array[String]
    def moved_since(commit, paths)
      clean!(@root, *paths)
      paths.reject { |path| tree(commit, path) == tree("HEAD", path) }
    end

    # Returns the tree id of path at commit, or nil when absent.
    #: (String commit, String path) -> String?
    def tree(commit, path)
      ok, out, = @ops.git(@root, "rev-parse", "#{commit}:#{path}")
      ok ? out.strip : nil
    end

    # Returns whether the report has a deploy whose steps all finished ok.
    #: () -> bool?
    def deployed?
      d = @report["deploy"]
      d && d["steps"].map { |s| s["name"] } - ["pins hold", "qemu gate"] == deploy_plan.map(&:first) && d["steps"].all? { |s| s["ok"] }
    end

    # Yields, sets the verdict, and returns the report; a Stop sets the verdict to fail.
    #: () { () -> void } -> Hash[String, untyped]
    def settle
      yield
      @report["verdict"] = verdict
      @report
    rescue Stop
      @report["verdict"] = "fail"
      @report
    end

    # Checks out the R2P2-darwin pins and returns a summary line.
    #: () -> String
    def pin_darwin
      lock = @lock.fetch("darwin")
      checkout(darwin_dir, lock.fetch("R2P2-darwin"))
      checkout(darwin_picoruby, lock.fetch("picoruby"))
      git!(darwin_picoruby, "submodule", "update", "--init", "--recursive")
      "R2P2-darwin #{lock['R2P2-darwin'][0, 7]}, picoruby #{lock['picoruby'][0, 7]}"
    end

    # Raises Stop unless the R2P2-darwin checkouts are at their pins.
    #: () -> String
    def darwin_pins_hold!
      lock = @lock.fetch("darwin")
      head_is!(darwin_dir, lock.fetch("R2P2-darwin"))
      head_is!(darwin_picoruby, lock.fetch("picoruby"))
    end

    BUILT_APPS = %w[ios watchos].freeze
    APP_CONNECTED = "[batch] Connected; dRuby pair bound"
    APP_END = "[batch] end"
    APP_BATCH_LIMIT_S = 120
    STOPPED_MARK = "[acceptance] stopped after"
    APP_WANTS = [APP_CONNECTED, "[batch] OK face=joy"].freeze

    # Builds the iOS and watchOS apps, runs the iPhone batch and the Mac to iPhone to Mac hand-off. Returns the report.
    #: () -> Hash[String, untyped]
    def run_darwin
      d = @report["darwin"] = { "steps" => [], "timings" => {} }
      settle do
        step(d, "pin R2P2-darwin") { pin_darwin }
        BUILT_APPS.each do |platform|
          %W[#{platform}:device:lib #{platform}:gen #{platform}:device:build].each { |t| step(d, t) { rake(t) } }
        end
        step(d, "pin R2P2-darwin holds") { darwin_pins_hold! }
        step(d, "quiet wait") { @quiet = quiet_wait_s; "#{@quiet} s" }
        step(d, "iPhone batch") do
          @ops.sleep(quiet)
          out, = app_batch!("connect;joy;selftest")
          APP_WANTS.each { |line| want!(out, line) }
          detail = out.lines.find { |l| l.start_with?("[batch] OK selftest detail=") }.to_s[DETAIL]
          raise Stop, "iPhone: no selftest detail in #{out.inspect}" unless detail
          detail
        end
        step(d, "hand-off Mac → iPhone → Mac") { apple_hand_off(d) }
      end
    end

    # Runs the batch lines on the iPhone and returns [console output, seconds]. Raises Stop on failure or timeout.
    #: (String lines) -> [String, Float]
    def app_batch!(lines)
      t0 = @ops.now
      ok, out, = run_rake(["ios:device:run"],
                          { "APP_CONSOLE" => "1", "APP_LAUNCH_ARGS" => "-StackchanBatch \"#{lines}\"" },
                          APP_BATCH_LIMIT_S)
      t = @ops.now - t0
      raise Stop, "iPhone: the batch did not end within #{APP_BATCH_LIMIT_S} s:\n#{out.to_s.lines.last(20).join}" if !ok && out.to_s.include?(STOPPED_MARK)
      raise Stop, "iPhone: ios:device:run failed:\n#{out.to_s.lines.last(20).join}" unless ok
      want!(out, APP_END)
      [out, t]
    end

    # Raises Stop unless out contains line as a whole line.
    #: (String out, String line) -> void
    def want!(out, line)
      return if out.to_s.lines.map(&:strip).include?(line)
      raise Stop, "iPhone: no #{line.inspect} in #{out.inspect}"
    end

    # Hands the robot Mac to iPhone to Mac, records the timings in d, and returns a summary line.
    #: (Hash[String, untyped] d) -> String
    def apple_hand_off(d)
      @ops.sleep(quiet)
      cli!("face", "neutral")
      c0 = status["connects"].to_i
      @ops.sleep(quiet)
      out, ti = app_batch!("joy")
      want!(out, "[batch] OK face=joy")
      @ops.sleep(quiet)
      tm = face!("neutral", {}, "the Mac does not get the robot back")
      c1 = status["connects"].to_i
      raise Stop, "Mac connects #{c0} -> #{c1}; want more than #{c0}" unless c1 > c0
      { "hand-off iPhone" => ti, "hand-off Mac" => tm }.each { |k, v| (d["timings"][k] ||= []) << v }
      format("iPhone %.2f s, Mac %.2f s", ti, tm)
    end

    # Re-runs only the touch step of the check and replaces it in the report. Returns the report. Raises Stop without a check.
    #: () -> Hash[String, untyped]
    def run_touch
      c = @report["check"]
      raise Stop, "report #{@report['stamp']} has no check; run acceptance:check" unless c
      fresh = { "steps" => [] }
      begin
        step(fresh, "touch listen") { touch }
      rescue Stop
        nil
      end
      touched = fresh["steps"].first
      i = c["steps"].index { |s| s["name"] == touched["name"] }
      i ? c["steps"][i] = touched : c["steps"] << touched
      @report["verdict"] = verdict
      @report
    end

    # Asks every question the check left unanswered (it ran without a TTY).
    # Asks every check question that is still unanswered. Returns the report.
    #: () -> Hash[String, untyped]
    def answer
      @report["check"]&.dig("human")&.each_value { |h| h["answer"] ||= @ops.prompt(h["question"]) }
      @report["verdict"] = verdict
      @report
    end

    # Returns "pass", "fail" or "incomplete" from the steps and the answers.
    #: () -> String
    def verdict
      d, c = @report.values_at("deploy", "check")
      all_steps = [d, c, @report["darwin"]].compact.flat_map { |p| p["steps"] }
      return "fail" if all_steps.any? { |s| s["ok"] == false }
      answers = c ? c["human"].values.map { |h| h["answer"] } : []
      return "fail" if answers.include?("n")
      ran = c ? c["steps"].map { |s| s["name"] } : []
      complete = deployed? && (check_plan.map(&:first) - ran).empty? &&
                 answers.all?("y") && all_steps.all? { |s| s["ok"] || s["name"] == "touch listen" }
      complete ? "pass" : "incomplete"
    end

    # --- pins -----------------------------------------------------------------

    # Checks out the pinned trees and returns a summary line. Raises Stop when HEAD is missing or a tree has local changes.
    #: () -> String
    def pin_trees
      root = head(@root)
      raise Stop, "#{@root} has no HEAD" unless root
      @report["root"] = root
      clean!(@root)
      checkout(r2p2, firmware.fetch("R2P2-ESP32"))
      git!(r2p2, "submodule", "update", "--init", "--recursive")
      firmware.fetch("repos").each { |name, want| pin_cache(name, want) }
      darwin = pin_darwin
      "stackchan-picoruby #{root[0, 7]}, R2P2-ESP32 #{firmware['R2P2-ESP32'][0, 7]}, " \
        "#{firmware['repos'].size} cached gems, #{darwin}"
    end

    # mruby's gem loader clones a missing gem at its branch tip and never pulls
    # an existing one, so each cache is put at its sha before anything builds.
    # A moved checkout keeps its old commit on a keep-<sha> branch.
    # Puts the fetched gem cache name at sha want, keeping a moved commit on a keep-<sha> branch.
    #: (String name, String want) -> void
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

    # Raises Stop unless every pinned tree is at its pin and clean. Returns "all pins hold".
    #: (aot: bool, ?root: bool) -> String
    def verify(aot:, root: true)
      if root
        head_is!(@root, @report["root"])
        clean!(@root)
      end
      head_is!(r2p2, firmware.fetch("R2P2-ESP32"))
      clean!(r2p2)
      head_is!(picoruby, firmware.fetch("picoruby"))
      firmware.fetch("repos").each { |name, want| head_is!(File.join(repos_dir, name), want) }
      firmware.fetch("aot", {}).each { |name, want| head_is!(File.join(@root, "build", "aot", name), want) } if aot
      "all pins hold"
    end

    # Fetches and checks out sha in dir detached. Returns the short sha.
    #: (String dir, String sha) -> String
    def checkout(dir, sha)
      git!(dir, "fetch", "--quiet", "origin", sha)
      git!(dir, "checkout", "--quiet", "--detach", sha)
      head_is!(dir, sha)
    end

    # Returns the HEAD sha of dir, or nil.
    #: (String dir) -> String?
    def head(dir)
      ok, out, = @ops.git(dir, "rev-parse", "HEAD")
      ok ? out.strip : nil
    end

    # Returns the short sha of want. Raises Stop unless HEAD of dir is want.
    #: (String dir, String want) -> String
    def head_is!(dir, want)
      have = head(dir)
      raise Stop, "#{dir} is at #{have.inspect}, lock says #{want}" unless have == want
      want[0, 7]
    end

    # Raises Stop when dir (limited to paths) has local changes.
    #: (String dir, *String paths) -> void
    def clean!(dir, *paths)
      out = git!(dir, "status", "--porcelain", "--untracked-files=no", *(["--", *paths] unless paths.empty?))
      raise Stop, "#{dir} has local changes:\n#{out}" unless out.strip.empty?
    end

    # --- device ---------------------------------------------------------------

    # Reads the flash identity and returns a summary line. Raises Stop unless the storage offset and App version match the pins.
    #: () -> String
    def flash_identity
      id = FlashIdentity.parse(rake_out("r2p2:flash_identity"))
      storage = id["partitions"].dig("storage", "offset")
      raise Stop, "flash has storage at #{storage.inspect}, not #{STORAGE_OFFSET}" unless storage == STORAGE_OFFSET
      version = id["app_version"]
      sha = FlashIdentity.sha_of(version)
      unless sha && firmware.fetch("R2P2-ESP32").start_with?(sha)
        raise Stop, "flash App version #{version.inspect} is not R2P2-ESP32 #{firmware['R2P2-ESP32'][0, 7]}"
      end
      "App version #{version}, storage #{storage}"
    end

    # Resets the board, captures the boot log and checks for faults and the boot markers. Returns a summary line. Raises Stop on a fault or a missing marker.
    #: () -> String
    def boot
      rake("r2p2:reset_and_capture", env: { "SERIAL_LOG" => boot_log, "DURATION" => BOOT_CAPTURE_S.to_s })
      text = @ops.read(boot_log).to_s.encode("UTF-8", invalid: :replace, undef: :replace)
      fault = text[FAULTS]
      raise Stop, "boot log shows #{fault.inspect} (#{boot_log})" if fault
      missing = firmware.fetch("boot_markers").reject { |m| text.include?(m) }
      raise Stop, "boot log lacks #{missing.inspect} (#{boot_log})" unless missing.empty?
      rake("r2p2:reset")
      "#{firmware['boot_markers'].size} markers, no fault"
    end

    # Runs pc:up until it succeeds. Returns a summary line. Raises Stop after PC_UP_TRIES failures.
    #: () -> String
    def pc_up
      t0 = @ops.now
      PC_UP_TRIES.times do |i|
        ok, out, = run_rake(["pc:up"], {})
        return format("up after %d tries, %.1f s", i + 1, @ops.now - t0) if ok
        raise Stop, "pc:up failed #{PC_UP_TRIES} times:\n#{out.to_s.lines.last(20).join}" if i + 1 == PC_UP_TRIES
        @ops.sleep(PC_UP_WAIT_S)
      end
    end

    # Returns the actual-position detail in out. Raises Stop when there is none.
    #: (String out) -> String
    def detail!(out)
      raise Stop, "no detail line in #{out.inspect}; servo health: #{servo_health}" unless out =~ DETAIL
      out[DETAIL]
    end

    # Speaks SAY_TEXT and returns the byte count. Raises Stop when the clip is too short.
    #: () -> String
    def say
      out = cli!("say", SAY_TEXT)
      bytes = out[/OK say bytes=(\d+)/, 1]
      raise Stop, "no `OK say bytes=` in #{out.inspect}" unless bytes
      raise Stop, "#{bytes} bytes fit in two chunks; the clip must span more" if bytes.to_i <= MULTICORE_CHUNK * 2
      "#{bytes} bytes"
    end

    # Returns the servo health reply of the robot.
    #: () -> String
    def servo_health
      _, out, = @ops.cli(@root, "remote", "servo_health")
      out.to_s.strip
    end

    # Records the last connect time in the check timings.
    #: () -> Array[Integer]?
    def record_connect_ms
      ms = status["last_connect_ms"]
      (@report["check"]["timings"]["connect ms"] ||= []) << ms.to_i if ms
    end

    # Returns the free robot stack. Raises Stop below STACK_FLOOR.
    #: () -> String
    def stack_high_water
      out = cli!("remote", "stack_free")
      free = out[/<stack_free:(\d+)>/, 1]
      raise Stop, "no stack reading in #{out.inspect}" unless free
      raise Stop, "#{free} B free, below #{STACK_FLOOR} B" if free.to_i < STACK_FLOOR
      "#{free} B free"
    end

    # Times servo, face, led and text commands for the configured rounds into the check timings. Returns a summary line.
    #: () -> String
    def measure
      t = @report["check"]["timings"]
      @rounds.times { (t["servo"] ||= []) << timed!("servo", "--yaw-left", "30", "--pitch-up", "10", "--time", "300") }
      @rounds.times { |i| (t["face"] ||= []) << timed!("face", FACES[i % FACES.size]) }
      @rounds.times { (t["led"] ||= []) << timed!("led", "both", "red", "solid") }
      @rounds.times { (t["text"] ||= []) << timed!("remote", "text", SUBTITLE) }
      "#{t.size} series"
    end

    # Asks the operator every question and records the answers. Returns a summary line.
    #: () -> String
    def ask
      h = @report["check"]["human"] = {}
      QUESTIONS.each { |key, q| h[key] = { "question" => q, "answer" => @ops.prompt(q) } }
      "#{h.size} questions"
    end

    # --- controller -----------------------------------------------------------

    # Returns the memoized quiet wait in seconds.
    #: () -> Integer
    def quiet = @quiet ||= quiet_wait_s

    # Returns the seconds the link needs to release, from hold_ms and release_after. Raises Stop when either is missing.
    #: () -> Integer
    def quiet_wait_s
      app = File.join(@root, firmware.fetch("app"))
      release_after = @ops.read(app).to_s[/release_after\s+([\d_]+)/, 1]
      raise Stop, "no `release_after` in #{app}" unless release_after
      hold = status["hold_ms"].to_s
      raise Stop, "`stackchan status` has no hold_ms" unless hold.match?(/\A\d+\z/)
      (hold.to_i + release_after.delete("_").to_i) / 1000 + 5
    end

    # Returns the key=value fields of `stackchan status`. Raises Stop without a link line.
    #: () -> Hash[String, String]
    def status
      out = cli!("status")
      line = out.lines.find { |l| l.start_with?("link=") }
      raise Stop, "no `link=` line in #{out.inspect}" unless line
      line.split.to_h { |kv| k, v = kv.split("=", 2); [k, v.to_s] }
    end

    # Waits for a head touch. Returns the touch line. Raises Pending without a TTY or a touch, Stop on failure.
    #: () -> String
    def touch
      raise Pending, "no TTY, nobody to touch the head" unless @ops.tty?
      @ops.notice("touch the back of the head")
      _, out, _, code = @ops.cli(@root, "touch", "listen", "--count", "1", "--timeout", "30")
      zone = out[/touch zone=\d.*/]
      raise Pending, "not touched within 30 s" if code != 0 && out.include?("[touch] timed out")
      raise Stop, "touch listen exit #{code}:\n#{out}" unless code == 0 && zone
      zone.strip
    end

    # Runs calibration and checks the zeros and the forward verify. Returns a summary line. Raises Stop on failure.
    #: () -> String
    def calibrate
      _, out, _, code = @ops.cli(@root, "calibrate", "--no-torque-toggle", "--format", "json", "--samples", "3", stdin: "\n" * 5)
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

    # Sends a chat prompt and checks for a real sidecar reply. Returns the reply line. Raises Stop otherwise.
    #: () -> String
    def chat
      _, out, _, code = @ops.cli(@root, "chat", "こんにちは", "--no-speak")
      reply = out.to_s[/^reply=(.*)$/, 1].to_s.strip
      if code != 0 || reply.empty? || reply == "(none)" || reply.start_with?("stub返答:")
        raise Stop, "chat exit #{code}; want a reply from the real sidecar:\n#{out}"
      end
      "reply=#{reply}"
    end

    # Waits for the link to release, sends a face to reconnect, and checks one new connect. Returns a summary line.
    #: () -> String
    def release_and_reconnect
      cli!("face", "neutral")
      c0 = status["connects"].to_i
      @ops.sleep(quiet)
      seen = status["link"] == "released"
      t = face!("joy", {}, "face joy after the release failed")
      c1 = status["connects"].to_i
      raise Stop, "connects #{c0} -> #{c1}, want #{c0 + 1}" unless c1 == c0 + 1
      (@report["check"]["timings"]["release and reconnect"] ||= []) << t
      format("release seen: %s, reconnect + face %.2f s", seen ? "yes" : "no", t)
    end

    # Sends a face and returns the seconds taken. Raises Stop with why on failure.
    #: (String face, Hash[String, String] env, String why) -> Float
    def face!(face, env, why)
      ok, out, t, code = @ops.cli(@root, "face", face, env: env)
      raise Stop, "#{why}: exit #{code}\n#{out}" unless ok && out.include?("OK face=")
      t
    end

    # --- plumbing -------------------------------------------------------------

    # Runs the block and appends its result to part's steps; Pending records an incomplete step, Stop a failed step and re-raises.
    #: (Hash[String, untyped] part, String name) { () -> untyped } -> void
    def step(part, name)
      detail = yield
      part["steps"] << { "name" => name, "ok" => true, "detail" => detail.to_s }
    rescue Pending => e
      part["steps"] << { "name" => name, "ok" => nil, "detail" => "incomplete: #{e.message}" }
    rescue Stop => e
      part["steps"] << { "name" => name, "ok" => false, "detail" => e.message }
      raise
    end

    # Returns the output of git in dir. Raises Stop on failure.
    #: (String dir, *String args) -> String
    def git!(dir, *args)
      ok, out, = @ops.git(dir, *args)
      raise Stop, "git -C #{dir} #{args.join(' ')} failed:\n#{out}" unless ok
      out
    end

    # Runs a rake task through ops, refusing flash writes outside the allowed phases. Returns [success, output, 0].
    #: (Array[String] tasks, Hash[String, String?] env, ?Numeric? limit) -> [bool, String, Integer]
    def run_rake(tasks, env, limit = nil)
      task = tasks.first
      if (FIRMWARE_WRITES + APP_WRITES).include?(task) && !@may_write.include?(task)
        raise Stop, "#{task} writes flash; the firmware only in acceptance:deploy, the app only in its app upload or acceptance:app"
      end
      @report["resets"] += 1 if RESETS.include?(task)
      return @ops.rake(@root, *tasks, env: env) unless limit
      @ops.rake(@root, *tasks, env: env, limit: limit)
    end

    # Runs a rake task and returns "ok". Raises Stop on failure.
    #: (*String tasks, ?env: Hash[String, String?]) -> String
    def rake(*tasks, env: {})
      rake_out(*tasks, env: env)
      "ok"
    end

    # Runs a rake task and returns its output. Raises Stop on failure.
    #: (*String tasks, ?env: Hash[String, String?]) -> String
    def rake_out(*tasks, env: {})
      ok, out, = run_rake(tasks, env)
      raise Stop, "rake #{tasks.join(' ')} failed in #{@root}:\n#{out.to_s.lines.last(20).join}" unless ok
      out.to_s
    end

    # Runs the stackchan CLI and returns its output. Raises Stop on failure.
    #: (*String args) -> String
    def cli!(*args)
      ok, out, = @ops.cli(@root, *args)
      raise Stop, "stackchan #{args.join(' ')} failed:\n#{out}" unless ok
      out
    end

    # Runs the stackchan CLI and returns the seconds taken. Raises Stop on failure.
    #: (*String args) -> Float
    def timed!(*args)
      ok, out, seconds = @ops.cli(@root, *args)
      raise Stop, "stackchan #{args.join(' ')} failed while timing:\n#{out}" unless ok
      seconds
    end

    # --- report ---------------------------------------------------------------

    # Returns the median of xs, or nil when empty.
    #: (Array[Numeric] xs) -> Numeric?
    def self.median(xs)
      s = xs.sort
      n = s.size
      return nil if n.zero?
      n.odd? ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2.0
    end

    # Returns the report label of a step.
    #: (Hash[String, untyped] s) -> String
    def mark(s) = s["ok"].nil? ? "incomplete" : (s["ok"] ? "ok" : "FAIL")

    # Returns the Markdown table of part's steps under title.
    #: (String title, Hash[String, untyped] part) -> String
    def table(title, part)
      out = +"\n## #{title}\n\n| step | ok | detail |\n|---|---|---|\n"
      part["steps"].each { |s| out << "| #{s['name']} | #{mark(s)} | #{s['detail'].to_s.lines.first.to_s.strip} |\n" }
      out
    end

    # Returns the report as Markdown.
    #: () -> String
    def markdown
      fw = firmware
      out = +"# Device acceptance #{@report['stamp']}\n\n**verdict: #{@report['verdict']}**\n\n"
      out << "## Pins\n\n"
      out << "- stackchan-picoruby `#{@report['root'].to_s[0, 7]}`\n"
      out << "- firmware: R2P2-ESP32 `#{fw['R2P2-ESP32'][0, 7]}`, picoruby `#{fw['picoruby'][0, 7]}`, "
      out << fw["repos"].map { |k, v| "#{k} `#{v[0, 7]}`" }.join(", ")
      out << ", " << fw["aot"].map { |k, v| "#{k} `#{v[0, 7]}`" }.join(", ") if fw["aot"]
      out << ", app `#{fw['app']}`\n"
      out << "- darwin: R2P2-darwin `#{@lock.dig('darwin', 'R2P2-darwin').to_s[0, 7]}`, picoruby `#{@lock.dig('darwin', 'picoruby').to_s[0, 7]}`\n" if @lock["darwin"]
      out << "\nBoard resets: #{@report['resets']}\n"
      out << table("deploy", @report["deploy"]) if @report["deploy"]
      if (c = @report["check"])
        out << table("check", c)
        out << "\n" << c["human"].map { |_, h| "- #{h['question']}: #{h['answer'] || 'unanswered'}" }.join("\n") << "\n" unless c["human"].empty?
        unless c["timings"].empty?
          out << "\n## Timings (median seconds, CLI round trip, #{@rounds} rounds)\n\n| series | median |\n|---|---|\n"
          c["timings"].each do |s, xs|
            m = self.class.median(xs)
            out << "| #{s} | #{m ? format('%.3f', m) : '—'} |\n"
          end
        end
      end
      out << table("darwin", @report["darwin"]) if @report["darwin"]
      out
    end
  end
end
