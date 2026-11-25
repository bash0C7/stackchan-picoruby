require "digest"
require "open3"
require "prism"

class TheoremMutants
  CONTROLLER = "mrbgems/picoruby-stackchan-controller/mrblib/stackchan-controller".freeze
  ROBOT      = "mrbgems/picoruby-stackchan-robot/mrblib/stackchan-robot".freeze
  PROTOCOL   = "mrbgems/picoruby-stackchan-protocol/mrblib/stackchan-protocol".freeze
  FACTS      = "theorems/extract/facts.rb".freeze

  TARGETS = [
    *%w[link central session send_builder args builder].map { |name| "#{CONTROLLER}/#{name}.rb" },
    *%w[link_loop peripheral dispatcher remote ticker handle head builder].map { |name| "#{ROBOT}/#{name}.rb" },
    "mrbgems/picoruby-drb-ble/mrblib/drb-ble.rb",
    *%w[frame_codec frame_parser frame_text].map { |name| "#{PROTOCOL}/#{name}.rb" },
    *%w[robot mac ios watchos].map { |name| "apps/#{name}/app.rb" },
  ].freeze

  OUTPACE = "every_controller_outpaces_the_robot".freeze

  HAND = [
    ["apps/robot/app.rb", "bot.release_after 15_000", "bot.release_after 4_000", OUTPACE],
    [CONTROLLER + "/link.rb", "keepalive_ms: 1_000", "keepalive_ms: 12_000", OUTPACE],
    ["apps/watchos/Sources/VMExecutor.swift", "repeating: 1.0", "repeating: 12.0", OUTPACE],
    ["#{CONTROLLER}/daemon.rb", "TICK_MS = 250", "TICK_MS = 12_000", OUTPACE],
    ["#{CONTROLLER}/central.rb", "ACK_TIMEOUT_MS            = 3_000", "ACK_TIMEOUT_MS            = 14_000", OUTPACE],
    ["acceptance/runner.rb", '["release and reconnect", ->', '["reconnect", ->', "every_assumption_has_a_step_that_looks_at_it"],
    [FACTS, "STATES = %w[released held quiet busy]", "STATES = %w[released held busy]", "every_link_tick_class_is_observed"],
    [FACTS, "%w[ok connectionError timeout timeoutLost otherError okLost].each", "%w[ok connectionError timeout].each",
     "every_link_action_class_is_observed"],
    [FACTS, "[nil, 2_000_000].each do |played|", "[nil].each do |played|", "every_robot_tick_class_is_observed"],
    [FACTS, "[0, 1, 15, 16].each do |queued|", "[0, 1].each do |queued|", "every_front_class_is_observed"],
    [FACTS, "[false, true].each do |waiting|", "[false].each do |waiting|", "every_face_class_is_observed"],
  ].freeze

  RADIO     = "BLE radio plumbing: connect, discovery, notifications, chunks, timeouts".freeze
  DIAGNOSIS = "diagnostics people read: stack_free, servo_health, the position detail, contract differences".freeze
  UNUSED    = "extension points no app declares: on_frame, remote handlers, on_boot, controller on_touch and every".freeze
  PLAYBACK  = "how long playback takes".freeze
  NO_CALLER = "code without a caller: FrameCodec touch parsing".freeze
  VOICE     = "what an AI reply or a synthesized voice says".freeze
  VERB      = "the CLI remote verb".freeze

  OUTSIDE = [
    *%w[connected? lost? link_lost reset_link connect disconnect keepalive drain remote call_front send_chunk poll
        raise_if_lost polls_for resolve_handles subscribe_tx settle handle_notification].map do |name|
      ["#{CONTROLLER}/central.rb", "Central##{name}", RADIO]
    end,
    ["#{CONTROLLER}/central.rb", "Central#self.differences", DIAGNOSIS],
    ["#{CONTROLLER}/central.rb", "Central#audio_done_timeout_ms", PLAYBACK],
    ["#{CONTROLLER}/session.rb", "Session#remote", VERB],
    ["#{CONTROLLER}/session.rb", "Session#prime", VOICE],
    ["#{CONTROLLER}/builder.rb", "Builder#on_touch", UNUSED],
    ["#{CONTROLLER}/builder.rb", "Builder#every", UNUSED],
    *%w[initialize pop_event event_popped take_write disconnect_central send_notification build_adv_data
        build_gatt_database drb_handle].map { |name| ["#{ROBOT}/peripheral.rb", "Peripheral##{name}", RADIO] },
    ["#{ROBOT}/dispatcher.rb", "Dispatcher#emit_servo_detail", DIAGNOSIS],
    *%w[stack_free servo_health err_label status_label].map { |name| ["#{ROBOT}/remote.rb", "Remote##{name}", DIAGNOSIS] },
    ["#{ROBOT}/remote.rb", "Remote#define_handler", UNUSED],
    ["#{ROBOT}/handle.rb", "Handle#say_ready?", DIAGNOSIS],
    ["#{ROBOT}/head.rb", "Head#read_health", DIAGNOSIS],
    *%w[on_boot on_frame remote].map { |name| ["#{ROBOT}/builder.rb", "Builder##{name}", UNUSED] },
    *["DRbBle#self.chunks", "Socket#initialize", "Socket#write", "Socket#read", "DRbBle#self.register", "DRbBle#self.socket",
      "DRb#create_socket"].map { |name| ["mrbgems/picoruby-drb-ble/mrblib/drb-ble.rb", name, RADIO] },
    ["#{PROTOCOL}/frame_codec.rb", "FrameCodec#self.touch_event?", NO_CALLER],
    ["#{PROTOCOL}/frame_codec.rb", "FrameCodec#self.parse_touch", NO_CALLER],
  ].freeze

  EQUIVALENT = {}.freeze

  EXTRACT_LIMIT_S = 120
  BUILD_LIMIT_S   = 900

  class Points < Prism::Visitor
    SWAP = { :< => "<=", :<= => "<", :> => ">=", :>= => ">", :== => "!=", :!= => "==" }.freeze
    KEEP = %i[require attr_reader attr_accessor attr_writer private include alias_method module_function].freeze
    WHOLE = [Prism::DefNode, Prism::ClassNode, Prism::ModuleNode, Prism::SingletonClassNode, Prism::ConstantWriteNode,
             Prism::ConstantPathWriteNode, Prism::AliasMethodNode].freeze

    attr_reader :out, :probes

    def initialize
      super()
      @out = []
      @probes = {}
      @owners = []
      @method = nil
    end

    def visit_class_node(node)
      within(node.constant_path.slice) { super }
    end

    def visit_module_node(node)
      within(node.constant_path.slice) { super }
    end

    def visit_def_node(node)
      outer = @method
      @method = "#{@owners.last}##{node.receiver ? "self." : ""}#{node.name}"
      @probes[@method] = node.body.location.start_offset if node.body
      super
      @method = outer
    end

    def visit_call_node(node)
      add(node.message_loc, SWAP[node.name], "#{node.name} -> #{SWAP[node.name]}") if SWAP[node.name] && node.message_loc
      super
    end

    def visit_and_node(node)
      add(node.operator_loc, node.operator == "and" ? "or" : "||", "&& -> ||")
      super
    end

    def visit_or_node(node)
      add(node.operator_loc, node.operator == "or" ? "and" : "&&", "|| -> &&")
      super
    end

    def visit_true_node(node)
      add(node.location, "false", "true -> false")
    end

    def visit_false_node(node)
      add(node.location, "true", "false -> true")
    end

    def visit_integer_node(node)
      add(node.location, (node.value + 1).to_s, "#{node.value} -> #{node.value + 1}")
      add(node.location, (node.value - 1).to_s, "#{node.value} -> #{node.value - 1}") if node.value.positive?
    end

    def visit_if_node(node)
      negate(node.predicate)
      super
    end

    def visit_unless_node(node)
      negate(node.predicate)
      super
    end

    def visit_statements_node(node)
      node.body.each do |child|
        next if WHOLE.any? { |kind| child.is_a?(kind) }
        next if child.is_a?(Prism::CallNode) && child.receiver.nil? && KEEP.include?(child.name)
        add(child.location, "nil", "delete #{child.slice.lines.first.strip[0, 50]}")
      end
      super
    end

    private

    def negate(predicate)
      add(predicate.location, "!(#{predicate.slice})", "negate #{predicate.slice[0, 50]}")
    end

    def within(owner)
      @owners.push(owner)
      yield
      @owners.pop
    end

    def add(loc, to, label)
      @out << [loc.start_offset, loc.end_offset, to, "#{loc.start_line}: #{label}", @method]
    end
  end

  def initialize(root:, vm:, only: nil, shard: nil)
    @root = root
    @vm = vm
    @only = only
    @shard, @shards = shard ? shard.split("/").map { |n| Integer(n) } : [0, 1]
  end

  def units
    all = []
    TARGETS.select { |file| @only.nil? || file.include?(@only) }.each do |file|
      source = File.binread(File.join(@root, file))
      points = Points.new
      Prism.parse(source).value.accept(points)
      mutants = Hash.new { |hash, key| hash[key] = [] }
      points.out.each do |from, to, text, label, method|
        mutated = splice(source, from, to, text)
        mutants[method] << [mutated, label] if Prism.parse(mutated).success?
      end
      mutants.each do |method, list|
        at = method && points.probes[method]
        all << [file, method, at && splice(source, at, at, "raise('probe'); "), list]
      end
    end
    all.select.with_index { |_unit, i| i % @shards == @shard }
  end

  def hand
    @only || @shard != 0 ? [] : HAND
  end

  def list
    found = units
    found.group_by(&:first).each do |file, group|
      puts "#{group.sum { |unit| unit[3].size }.to_s.rjust(5)} mutants in #{group.size.to_s.rjust(3)} units  #{file}"
    end
    puts "#{found.sum { |unit| unit[3].size }} generated in #{found.size} units, #{HAND.size} by hand"
    0
  end

  def probe
    out, verdict = build
    return (puts out; 1) unless verdict == :ok
    @baseline = facts_digest
    units.each do |file, method, probe, mutants|
      state = if outside(file, method) then "OUTSIDE"
              elsif probe.nil? then "ALWAYS"
              elsif seen?(file, probe) then "SEEN"
              else "UNSEEN"
              end
      puts "#{state.ljust(8)} #{mutants.size.to_s.rjust(4)} #{file} [#{method}]"
    end
    0
  end

  def run
    out, verdict = build
    unless verdict == :ok
      puts out
      puts "unmutated code FAILS"
      return 1
    end
    @baseline = facts_digest
    verdicts = Hash.new(0)
    failures = stale_outside
    failures.each { |line| puts line }
    units.each do |file, method, probe, mutants|
      if outside(file, method)
        verdicts[:outside] += mutants.size
        next
      end
      if probe && !seen?(file, probe)
        verdicts[:unseen] += mutants.size
        failures << "UNSEEN   #{file} [#{method}]: no fact calls it (#{mutants.size} mutants)"
        puts failures.last
        next
      end
      mutants.each do |mutated, label|
        verdict, detail = judge_text(file, mutated)
        verdict = :equivalent if verdict == :survived && EQUIVALENT.key?([file, method, label.sub(/\A\d+: /, "")])
        verdicts[verdict] += 1
        line = "#{verdict.to_s.upcase.ljust(8)} #{file}:#{label} [#{method}]#{detail}"
        failures << line if verdict == :survived
        puts line
      end
    end
    killed = hand.map do |file, from, to, expected|
      verdict = judge_hand(file, from, to, expected)
      verdicts["hand #{verdict}"] += 1
      verdict
    end
    puts verdicts.map { |name, n| "#{n} #{name}" }.join(", ")
    failures.empty? && killed.all?(:killed) ? 0 : 1
  end

  private

  def splice(source, from, to, text)
    source.byteslice(0, from) + text + source.byteslice(to, source.bytesize - to)
  end

  def stale_outside
    oracle = File.read(File.join(@root, "theorems/Theorems/Oracle.lean"))
    OUTSIDE.filter_map do |file, method, reason|
      next "OUTSIDE  #{file} [#{method}]: #{reason.inspect} is not in Oracle.outside" unless oracle.include?("(#{reason.inspect},")
      points = Points.new
      Prism.parse(File.binread(File.join(@root, file))).value.accept(points)
      "OUTSIDE  #{file} [#{method}]: no such method" unless points.probes.key?(method)
    end
  end

  def outside(file, method)
    OUTSIDE.find { |f, m, _reason| f == file && m == method }
  end

  def seen?(file, probe)
    path = File.join(@root, file)
    original = File.binread(path)
    File.binwrite(path, probe)
    _out, status = capture([@vm, File.join(@root, FACTS), @root], EXTRACT_LIMIT_S)
    status != :ok || facts_digest != @baseline
  ensure
    File.binwrite(path, original) if original
  end

  def judge_text(file, mutated)
    path = File.join(@root, file)
    original = File.binread(path)
    File.binwrite(path, mutated)
    out, verdict = build
    return [:crashed, " (#{verdict})"] if verdict == :extract_failed || verdict == :extract_timeout
    return [:survived, " (facts unchanged)"] if verdict == :same
    return [:survived, " (facts changed, theorems pass)"] if verdict == :ok
    names = failed_theorems(out)
    return [:crashed, " (facts unreadable)"] if names.empty?
    [:killed, " by #{names.join(", ")}"]
  ensure
    File.binwrite(path, original) if original
  end

  def judge_hand(file, from, to, expected)
    path = File.join(@root, file)
    original = File.read(path)
    unless original.scan(from).size == 1
      puts "BROKEN   #{expected}: #{file} does not hold #{from[0, 60].inspect} exactly once"
      return :broken
    end
    File.write(path, original.sub(from) { to })
    out, verdict = build
    names = %i[ok same].include?(verdict) ? [] : failed_theorems(out)
    result = if %i[ok same].include?(verdict) then :survived
             elsif names.include?(expected) then :killed
             else :broken
             end
    puts "#{result.to_s.upcase.ljust(8)} #{expected} <- #{file}: #{to.strip.lines.first.to_s.strip[0, 60].inspect}" \
         "#{result == :broken ? " failed instead: #{names.join(", ")}" : ""}"
    result
  ensure
    File.write(path, original) if original
  end

  def build
    out, status = capture([@vm, File.join(@root, FACTS), @root], EXTRACT_LIMIT_S)
    return [out, status == :timeout ? :extract_timeout : :extract_failed] unless status == :ok
    return [out, :same] if @baseline && facts_digest == @baseline
    lean, status = capture([File.join(@root, "bin/lean"), "build"], BUILD_LIMIT_S)
    [lean, status == :ok ? :ok : :failed]
  end

  def facts_digest
    Digest::SHA256.hexdigest(Dir[File.join(@root, "theorems/Theorems/Facts/*.lean")].sort.map { |f| File.binread(f) }.join)
  end

  def capture(command, limit)
    Open3.popen2e(*command) do |stdin, out, wait|
      stdin.close
      reader = Thread.new { out.read }
      unless wait.join(limit)
        Process.kill("KILL", wait.pid)
        wait.join
        return [reader.value, :timeout]
      end
      [reader.value, wait.value.success? ? :ok : :failed]
    end
  end

  def failed_theorems(out)
    out.scan(/^error: (Theorems(?:\/\w+)?\.lean):(\d+):/).map do |file, line|
      next "Theorems.lean" if file == "Theorems.lean"
      lines = File.readlines(File.join(@root, "theorems", file)).first(line.to_i)
      lines.reverse.find { |text| text.start_with?("theorem ") }.to_s.split[1].to_s.delete_suffix(":")
    end.uniq
  end
end
