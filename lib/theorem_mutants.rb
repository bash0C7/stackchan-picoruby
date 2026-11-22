require "open3"

class TheoremMutants
  CONTROLLER = "mrbgems/picoruby-stackchan-controller/mrblib/stackchan-controller".freeze
  ROBOT      = "mrbgems/picoruby-stackchan-robot/mrblib/stackchan-robot".freeze
  LINK       = "#{CONTROLLER}/link.rb".freeze
  LINK_LOOP  = "#{ROBOT}/link_loop.rb".freeze
  PERIPHERAL = "#{ROBOT}/peripheral.rb".freeze
  FACTS      = "theorems/extract/facts.rb".freeze

  TICKS   = "the_link_ticks_as_modeled".freeze
  ACTS    = "the_link_acts_as_modeled".freeze
  LOOP    = "the_robot_loop_ticks_as_modeled".freeze
  BUDGET  = "every_controller_declares_its_hold_in_budget".freeze
  ASKED   = "every_controller_speaks_only_when_asked".freeze
  OUTPACE = "every_controller_outpaces_the_robot".freeze

  MUTANTS = [
    [LINK, "now - @last_action_at >= @hold", "now - @last_action_at > @hold", TICKS],
    [LINK, "if expire && @hold &&", "if @hold &&", TICKS],
    [LINK, "return if @state == :quiet\n", "\n", TICKS],
    [LINK, "return if now - @last_sent_at < @keepalive_ms", "return if now - @last_sent_at <= @keepalive_ms", TICKS],
    [LINK, "return if @state == :released || @state == :busy\n        @central.drain",
     "return if @state == :released\n        connect! if @state == :busy\n        @central.drain", TICKS],
    [LINK, "        @touches.clear\n", "", TICKS],
    [LINK, "        @last_sent_at = now\n", "", TICKS],
    [LINK, "        @state = :released\n        @releases += 1", "        @state = :released\n        @hidden = 1\n        @releases += 1",
     "the_link_keeps_no_state_the_model_lacks"],
    [LINK, "connect! if @state == :released || @state == :busy", "connect! if @state == :released", ACTS],
    [LINK, "          lost! if @central.lost?\n          raise e\n        end\n        lost! if",
     "          lost! if @central.lost?\n          result = yield\n        end\n        lost! if", ACTS],
    [LINK, "used! unless @state == :released", "nil", ACTS],
    [LINK, "raise Busy, BUSY_MESSAGE", "nil", ACTS],
    [LINK, "keepalive_ms: 1_000", "keepalive_ms: 12_000", OUTPACE],
    [LINK_LOOP, "return if @clock.call - @active_at < @release_after_us", "return if @clock.call - @active_at <= @release_after_us", LOOP],
    [LINK_LOOP, "        @active_at = nil\n        @port.disconnect_central", "        @port.disconnect_central", LOOP],
    [LINK_LOOP, "        @active_at = nil\n        @drb.disconnected", "        @drb.disconnected", LOOP],
    [LINK_LOOP, "if @remote.perform_audio_play && @active_at", "if @remote.perform_audio_play", LOOP],
    [LINK_LOOP, "@active_at = @clock.call if @drb.service(@port)", "@drb.service(@port)", LOOP],
    [LINK_LOOP, "        @ticker.tick(@clock.call / 1000)", "        @hidden = 1\n        @ticker.tick(@clock.call / 1000)",
     "the_robot_loop_keeps_no_state_the_model_lacks"],
    [PERIPHERAL, "          @link.central_arrived\n", "          nil\n", LOOP],
    [PERIPHERAL, "          @link.disconnected\n", "", LOOP],
    ["apps/ios/app.rb", "  c.hold 10_000\n", "", BUDGET],
    ["apps/watchos/app.rb", "c.hold 10_000", "c.hold 20_000", BUDGET],
    ["apps/robot/app.rb", "  bot.release_after 15_000\n", "", BUDGET],
    ["apps/robot/app.rb", "bot.release_after 15_000", "bot.release_after 30_000", BUDGET],
    ["apps/robot/app.rb", "bot.release_after 15_000", "bot.release_after 4_000", OUTPACE],
    ["apps/mac/app.rb", "  c.hold 10_000\n", "  c.hold 10_000\n  c.every(1_000) { |s| s.face(:joy) }\n", ASKED],
    ["apps/mac/app.rb", "  c.hold 10_000\n", "  c.hold 10_000\n  c.on_touch { |s, _zone| s.face(:joy) }\n", ASKED],
    ["apps/watchos/Sources/VMExecutor.swift", "repeating: 1.0", "repeating: 12.0", OUTPACE],
    ["#{CONTROLLER}/daemon.rb", "TICK_MS = 250", "TICK_MS = 12_000", OUTPACE],
    ["#{CONTROLLER}/central.rb", "ACK_TIMEOUT_MS            = 3_000", "ACK_TIMEOUT_MS            = 14_000", OUTPACE],
    ["acceptance/runner.rb", '["release and reconnect", ->', '["reconnect", ->', "every_assumption_has_a_step_that_looks_at_it"],
    [FACTS, "STATES = %w[released held quiet busy]", "STATES = %w[released held busy]", "every_link_tick_class_is_observed"],
    [FACTS, "%w[ok connectionError timeout timeoutLost otherError okLost].each", "%w[ok connectionError timeout].each",
     "every_link_action_class_is_observed"],
    [FACTS, "[nil, 2_000_000].each do |played|", "[nil].each do |played|", "every_robot_tick_class_is_observed"],
  ].freeze

  def initialize(root:, vm:)
    @root = root
    @vm = vm
  end

  def run
    verdicts = MUTANTS.map { |file, from, to, expected| judge(file, from, to, expected) }
    out, ok = build
    puts out unless ok
    killed = verdicts.count(:killed)
    puts "#{killed} killed, #{verdicts.count(:survived)} survived, #{verdicts.count(:broken)} broken; " \
         "unmutated code #{ok ? "passes" : "FAILS"}"
    killed == MUTANTS.size && ok ? 0 : 1
  end

  private

  def judge(file, from, to, expected)
    path = File.join(@root, file)
    original = File.read(path)
    unless original.scan(from).size == 1
      puts "BROKEN   #{expected}: #{file} does not hold #{from[0, 60].inspect} exactly once"
      return :broken
    end
    File.write(path, original.sub(from) { to })
    out, ok = build
    verdict, detail = classify(out, ok, expected)
    puts "#{verdict.to_s.upcase.ljust(8)} #{expected} <- #{file}: #{to.strip.lines.first.to_s.strip[0, 60].inspect}#{detail}"
    verdict
  ensure
    File.write(path, original) if original
  end

  def classify(out, ok, expected)
    return [:survived, ""] if ok
    names = failed_theorems(out)
    return [:killed, ""] if names.include?(expected)
    [:broken, " failed instead: #{names.empty? ? out.lines.last(5).join : names.join(", ")}"]
  end

  def build
    out, status = Open3.capture2e(@vm, File.join(@root, FACTS), @root)
    return [out, false] unless status.success?
    lean, status = Open3.capture2e(File.join(@root, "bin/lean"), "build")
    [lean, status.success?]
  end

  def failed_theorems(out)
    out.scan(/^error: (Theorems\/\w+\.lean):(\d+):/).map do |file, line|
      lines = File.readlines(File.join(@root, "theorems", file)).first(line.to_i)
      lines.reverse.find { |text| text.start_with?("theorem ") }.to_s.split[1].to_s.delete_suffix(":")
    end.uniq
  end
end
