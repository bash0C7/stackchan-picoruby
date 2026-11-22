REPO = ARGV[0]
OUT  = "#{REPO}/theorems/Theorems/Facts"

def require(_name)
  true
end

module Machine
  def self.delay_ms(_ms)
  end
end

class BLE
  READ = 1
  WRITE = 2
  WRITE_WITHOUT_RESPONSE = 4
  NOTIFY = 8
  INDICATE = 16
  DYNAMIC = 32
  HCI_STATE_WORKING = 2
end

CONTROLLER = "#{REPO}/mrbgems/picoruby-stackchan-controller/mrblib"
ROBOT      = "#{REPO}/mrbgems/picoruby-stackchan-robot/mrblib"

load "#{CONTROLLER}/stackchan-controller.rb"
%w[errors link builder central daemon].each { |name| load "#{CONTROLLER}/stackchan-controller/#{name}.rb" }
load "#{ROBOT}/stackchan-robot.rb"
%w[face handle builder].each { |name| load "#{ROBOT}/stackchan-robot/#{name}.rb" }
%w[dispatcher remote link_loop peripheral].each { |name| load "#{ROBOT}/stackchan-robot/#{name}.rb" }

class ScriptedCentral
  attr_accessor :lost, :connects, :reply, :drain_loses
  attr_reader :calls

  def initialize
    @lost = false
    @connects = true
    @reply = "empty"
    @drain_loses = false
    @calls = []
  end

  def lost?
    @lost
  end

  def drain
    @lost = true if @drain_loses
  end

  def reset_link
    @calls << "reset"
  end

  def connect
    @calls << "connect"
    raise StackChan::Controller::ConnectionError, "refused" unless @connects
    @lost = false
    @drain_loses = false
  end

  def keepalive
    @calls << "keepalive"
    case @reply
    when "zone"
      [1]
    when "connectionError"
      raise StackChan::Controller::ConnectionError, "gone"
    when "timeout"
      raise StackChan::Controller::TimeoutError, "silent"
    when "timeoutLost"
      @lost = true
      raise StackChan::Controller::TimeoutError, "silent"
    else
      []
    end
  end
end

LINK_STATE = []
LOOP_STATE = []

def note_state(list, object)
  object.instance_variables.each { |name| list << name.to_s unless list.include?(name.to_s) }
end

def bool(value)
  value ? "true" : "false"
end

def opt(value)
  value.nil? ? "none" : "(some #{value})"
end

def list(names)
  "[#{names.map { |name| ".#{name}" }.join(", ")}]"
end

def link_term(link)
  status = link.status
  "⟨.#{status[:link]}, #{link.instance_variable_get(:@last_action_at)}, " \
    "#{link.instance_variable_get(:@last_sent_at)}, #{link.touches.size}, #{status[:releases]}, #{status[:connects]}⟩"
end

def build_link(state, hold, now, action_age, sent_age, touches)
  central = ScriptedCentral.new
  link = StackChan::Controller::Link.new(central: central, clock: -> { now }, hold: hold, log: ->(_line) {})
  link.instance_variable_set(:@state, state.to_sym)
  link.instance_variable_set(:@last_action_at, now - action_age)
  link.instance_variable_set(:@last_sent_at, now - sent_age)
  touches.times { link.touches.push(2) }
  [link, central]
end

STATES = %w[released held quiet busy]
NOW = 100_000

def edges(limit)
  [0, limit - 1, limit, limit + 1]
end

def link_tick_rows(rows, hold, keepalive)
  STATES.each do |state|
    edges(hold || 10_000).each do |action_age|
      edges(keepalive).each do |sent_age|
        [0, 1].each do |touches|
          [false, true].each do |drain_loses|
            [true, false].each do |expire|
              %w[empty zone connectionError timeout timeoutLost].each do |reply|
                link, central = build_link(state, hold, NOW, action_age, sent_age, touches)
                central.drain_loses = drain_loses
                central.reply = reply
                before = link_term(link)
                link.tick(expire: expire)
                note_state(LINK_STATE, link)
                rows << "(#{opt(hold)}, ⟨#{NOW}, #{bool(expire)}, #{bool(drain_loses)}, .#{reply}⟩, #{before}, " \
                        "#{link_term(link)}, #{list(central.calls)})"
              end
            end
          end
        end
      end
    end
  end
end

def run_act(link, central, body)
  ran = 0
  result = begin
    link.act do
      ran += 1
      case body
      when "connectionError"
        raise StackChan::Controller::ConnectionError, "gone"
      when "timeout"
        raise StackChan::Controller::TimeoutError, "silent"
      when "timeoutLost"
        central.lost = true
        raise StackChan::Controller::TimeoutError, "silent"
      when "otherError"
        raise StackChan::Controller::DeviceError, "rejected"
      when "okLost"
        central.lost = true
      end
    end
    "ok"
  rescue StackChan::Controller::Busy
    "busy"
  rescue StackChan::Controller::ConnectionError
    "connectionError"
  rescue StackChan::Controller::TimeoutError
    "timeoutError"
  rescue StackChan::Controller::DeviceError
    "otherError"
  end
  [ran, result]
end

def link_act_rows(rows)
  STATES.each do |state|
    [0, 1].each do |touches|
      [false, true].each do |drain_loses|
        [true, false].each do |connects|
          %w[ok connectionError timeout timeoutLost otherError okLost].each do |body|
            link, central = build_link(state, 10_000, NOW, 5_000, 500, touches)
            central.drain_loses = drain_loses
            central.connects = connects
            before = link_term(link)
            ran, result = run_act(link, central, body)
            note_state(LINK_STATE, link)
            rows << "(⟨#{NOW}, #{bool(drain_loses)}, #{bool(connects)}, .#{body}⟩, #{before}, " \
                    "⟨#{link_term(link)}, #{list(central.calls)}, #{ran}, .#{result}⟩)"
          end
        end
      end
    end
  end
end

class ScriptedPort
  attr_reader :cuts

  def initialize(event)
    @event = event
    @cuts = 0
  end

  def pop_event(timeout_ms:)
    @event
  end

  def event_popped
  end

  def disconnect_central
    @cuts += 1
  end
end

class ScriptedDrb
  def initialize(active)
    @active = active
  end

  def service(_port)
    @active
  end

  def disconnected
  end
end

class ScriptedSpeakerRemote
  def initialize(play)
    @play = play
  end

  def perform_audio_play
    @play.call
  end
end

class SilentTicker
  def tick(_now_ms)
  end
end

class ScriptedPeripheral < StackChan::Robot::Peripheral
  def initialize(link)
    @link = link
    @adv_data = ""
  end

  def advertise(_data)
  end

  def puts(*_lines)
  end
end

PACKETS = {
  "none"         => nil,
  "arrived"      => "\xB5\x02\x00",
  "disconnected" => "\x05\x04\x00",
  "other"        => "\x60\x01\x02",
  "notAString"   => :heartbeat,
}

def link_loop_rows(rows, release_after)
  now = 50_000_000
  release = release_after && release_after * 1000
  ages = [nil] + edges(release || 15_000_000)
  ages.each do |age|
    PACKETS.each do |name, event|
      [false, true].each do |traffic|
        [nil, 2_000_000].each do |played|
          time = now
          port = ScriptedPort.new(event)
          peripheral = nil
          link = StackChan::Robot::LinkLoop.new(
            port: port, ticker: SilentTicker.new,
            on_packet: ->(packet) { peripheral.packet_callback(packet) },
            clock: -> { time },
            drb: ScriptedDrb.new(traffic),
            remote: ScriptedSpeakerRemote.new(-> { played ? (time += played; true) : nil }),
            release_after: release_after
          )
          peripheral = ScriptedPeripheral.new(link)
          link.instance_variable_set(:@active_at, age && now - age)
          link.tick
          note_state(LOOP_STATE, link)
          rows << "(#{opt(release)}, ⟨#{now}, .#{name}, #{bool(traffic)}, #{opt(played)}⟩, #{opt(age && now - age)}, " \
                  "#{opt(link.instance_variable_get(:@active_at))}, #{port.cuts})"
        end
      end
    end
  end
end

class StackChan::Robot
  def run
    self
  end
end

def read(path)
  File.open("#{REPO}/#{path}", "r") { |file| file.read }
end

def after(text, mark, stop)
  at = text.index(mark)
  raise "#{mark} not found" unless at
  from = at + mark.size
  text[from...text.index(stop, from)]
end

def tick_ms(name)
  return StackChan::Controller::Daemon::TICK_MS if name == "mac"
  seconds = after(read("apps/#{name}/Sources/VMExecutor.swift"), "repeating: ", ")")
  raise "#{name}: tick period #{seconds.inspect}" unless seconds.to_f > 0
  (seconds.to_f * 1000).to_i
end

def acceptance_steps
  names = []
  read("acceptance/runner.rb").split("\n").each do |line|
    names << after(line, "[\"", "\"") if line.include?("[\"") && line.include?("\", ->")
    names << after(line, "step(d, \"", "\"") if line.include?("step(d, \"")
  end
  raise "no acceptance step found" if names.empty?
  names
end

def controller_apps
  names = %w[mac ios watchos]
  names.map do |name|
    load "#{REPO}/apps/#{name}/app.rb"
    app = App
    Object.send(:remove_const, :App)
    "⟨\"#{name}\", #{opt(app.hold_ms)}, #{app.touch_handlers.size}, #{app.periodic.size}, #{tick_ms(name)}⟩"
  end
end

def robot_release_after
  robot = nil
  StackChan.singleton_class.alias_method(:declare_robot, :robot)
  StackChan.define_singleton_method(:robot) do |&block|
    robot = declare_robot(&block)
    robot
  end
  load "#{REPO}/apps/robot/app.rb"
  robot.release_after
end

class Table
  CHUNK = 250

  attr_reader :size

  def initialize(file, name, type)
    @file = file
    @name = name
    @type = type
    @parts = 0
    @size = 0
  end

  def <<(row)
    open_part if @size % CHUNK == 0
    @file.write(",") unless @size % CHUNK == 0
    @file.write("\n  #{row}")
    @size += 1
    close_part if @size % CHUNK == 0
    self
  end

  def finish
    close_part unless @size % CHUNK == 0
    names = []
    @parts.times { |i| names << "#{@name}#{i}" }
    @file.write("def #{@name} : List #{@type} :=\n  #{names.join(" ++ ")}\n\n")
  end

  private

  def open_part
    @file.write("set_option maxRecDepth #{CHUNK * 8} in\ndef #{@name}#{@parts} : List #{@type} := [")
  end

  def close_part
    @file.write("\n]\n\n")
    @parts += 1
  end
end

def table(file, name, type)
  rows = Table.new(file, name, type)
  yield rows
  rows.finish
  rows.size
end

def strings(values)
  "[#{values.map { |value| "\"#{value}\"" }.join(", ")}]"
end

def facts(name, model)
  File.open("#{OUT}/#{name}.lean", "w") do |file|
    file.write("import Theorems.#{model}\n\n") if model
    file.write("namespace Theorems.Facts.#{name}\n\n")
    file.write("open Theorems.#{model}\n\n") if model
    yield file
    file.write("end Theorems.Facts.#{name}\n")
  end
end

release_after = robot_release_after
keepalive = StackChan::Controller::Link.new(central: nil, log: nil).instance_variable_get(:@keepalive_ms)
counts = []

facts("Link", "Link") do |file|
  file.write("def keepalive : Nat := #{keepalive}\n\n")
  counts << table(file, "observedTicks", "(Option Nat × TickIn × Link × Link × List Call)") do |rows|
    link_tick_rows(rows, 10_000, keepalive)
    link_tick_rows(rows, nil, keepalive)
  end
  counts << table(file, "observedActs", "(ActIn × Link × ActOut)") { |rows| link_act_rows(rows) }
  file.write("def state : List String := #{strings(LINK_STATE)}\n\n")
end

facts("LinkLoop", "LinkLoop") do |file|
  counts << table(file, "observedTicks", "(Option Nat × TickIn × Option Nat × Option Nat × Nat)") do |rows|
    link_loop_rows(rows, release_after)
    link_loop_rows(rows, nil)
  end
  file.write("def state : List String := #{strings(LOOP_STATE)}\n\n")
end

facts("Apps", nil) do |file|
  file.write("structure App where\n  name : String\n  hold : Option Nat\n  touchHandlers : Nat\n  periodic : Nat\n  tickMs : Nat\n" \
             "  deriving DecidableEq, Repr\n\n")
  file.write("def controllers : List App := [#{controller_apps.join(", ")}]\n\n")
  file.write("def releaseAfter : Option Nat := #{opt(release_after)}\n\n")
  file.write("def ackTimeoutMs : Nat := #{StackChan::Controller::Central::ACK_TIMEOUT_MS}\n\n")
  file.write("def acceptanceSteps : List String := #{strings(acceptance_steps)}\n\n")
end

puts "facts: #{counts[0]} link ticks, #{counts[1]} link actions, #{counts[2]} robot ticks"
