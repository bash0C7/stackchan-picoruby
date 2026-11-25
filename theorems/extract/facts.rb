REPO = ARGV[0]
OUT  = "#{REPO}/theorems/Theorems/Facts"

def require(_name)
  true
end

def sleep_ms(_ms)
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

PICORUBY_DRB = "#{ENV["PICORUBY_ROOT"] || "#{REPO}/vendor/R2P2-ESP32/components/picoruby-esp32/picoruby"}/mrbgems/picoruby-drb/mrblib"
PROTOCOL   = "#{REPO}/mrbgems/picoruby-stackchan-protocol/mrblib"
CONTROLLER = "#{REPO}/mrbgems/picoruby-stackchan-controller/mrblib"
ROBOT      = "#{REPO}/mrbgems/picoruby-stackchan-robot/mrblib"

%w[drb drb_message drb_object].each { |name| load "#{PICORUBY_DRB}/#{name}.rb" }
load "#{REPO}/mrbgems/picoruby-drb-ble/mrblib/drb-ble.rb"
load "#{PROTOCOL}/stackchan-protocol.rb"
%w[frame_codec frame_parser frame_text].each { |name| load "#{PROTOCOL}/stackchan-protocol/#{name}.rb" }
load "#{CONTROLLER}/stackchan-controller.rb"
%w[errors link builder args send_builder session calibration central daemon].each { |name| load "#{CONTROLLER}/stackchan-controller/#{name}.rb" }
load "#{ROBOT}/stackchan-robot.rb"
%w[face handle builder].each { |name| load "#{ROBOT}/stackchan-robot/#{name}.rb" }
%w[head ticker dispatcher remote link_loop peripheral].each { |name| load "#{ROBOT}/stackchan-robot/#{name}.rb" }

class ScriptedCentral
  attr_accessor :lost, :connects, :reply, :drain_loses
  attr_reader :calls

  def initialize
    @lost = false
    @connects = "ok"
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
    raise StackChan::Controller::ConnectionError, "refused" if @connects == "refused"
    raise StackChan::Controller::ContractMismatch, "contract differs" if @connects == "mismatch"
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
GATE_STATE = []
LOOP_STATE = []
REMOTE_STATE = []
TICKER_STATE = []
ACTIONS = []

def note_state(list, object)
  object.instance_variables.each { |name| list << name.to_s unless list.include?(name.to_s) }
end

def occurrences(items, item)
  n = 0
  items.each { |x| n += 1 if x == item }
  n
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
  link.on_lost = -> { central.calls << "lost" }
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
                lost = occurrences(central.calls, "lost")
                rows << "(#{opt(hold)}, ⟨#{NOW}, #{bool(expire)}, #{bool(drain_loses)}, .#{reply}⟩, #{before}, " \
                        "#{link_term(link)}, #{list(central.calls - ["lost"])}, #{lost})"
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
  returned = nil
  result = begin
    returned = link.act do
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
      :body
    end
    "ok"
  rescue StackChan::Controller::Busy
    "busy"
  rescue StackChan::Controller::ContractMismatch
    "mismatch"
  rescue StackChan::Controller::ConnectionError
    "connectionError"
  rescue StackChan::Controller::TimeoutError
    "timeoutError"
  rescue StackChan::Controller::DeviceError
    "otherError"
  end
  [ran, result, returned == :body]
end

def link_act_rows(rows)
  STATES.each do |state|
    [0, 1].each do |touches|
      [false, true].each do |drain_loses|
        %w[ok refused mismatch].each do |connects|
          %w[ok connectionError timeout timeoutLost otherError okLost].each do |body|
            link, central = build_link(state, 10_000, NOW, 5_000, 500, touches)
            central.drain_loses = drain_loses
            central.connects = connects
            before = link_term(link)
            ran, result, passes = run_act(link, central, body)
            note_state(LINK_STATE, link)
            lost = occurrences(central.calls, "lost")
            rows << "(⟨#{NOW}, #{bool(drain_loses)}, .#{connects}, .#{body}⟩, #{before}, " \
                    "⟨#{link_term(link)}, #{list(central.calls - ["lost"])}, #{ran}, .#{result}⟩, #{lost}, #{bool(passes)}, " \
                    "#{link.generation}, #{opt(link.status[:last_connect_ms])})"
          end
        end
      end
    end
  end
end

def link_listen_rows(rows)
  STATES.each do |state|
    link, _central = build_link(state, 10_000, NOW, 5_000, 500, 0)
    before = link_term(link)
    link.listening!
    note_state(LINK_STATE, link)
    rows << "(#{before}, #{link_term(link)})"
  end
end

class ScriptedPort
  attr_reader :cuts, :waits, :popped

  def initialize(event)
    @event = event
    @cuts = 0
    @waits = []
    @popped = 0
  end

  def pop_event(timeout_ms:)
    @waits << timeout_ms
    @event
  end

  def event_popped
    @popped += 1
  end

  def disconnect_central
    @cuts += 1
  end
end

class ScriptedDrb
  attr_reader :resets

  def initialize(active)
    @active = active
    @resets = 0
  end

  def service(_port)
    @active
  end

  def disconnected
    @resets += 1
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
  attr_reader :seen

  def initialize
    @seen = []
  end

  def tick(now_ms)
    @seen << now_ms
  end
end

class ScriptedPeripheral < StackChan::Robot::Peripheral
  attr_reader :advertised

  def initialize(link)
    @link = link
    @adv_data = ""
    @advertised = 0
  end

  def advertise(_data)
    @advertised += 1
  end

  def puts(*_lines)
  end
end

PACKETS = {
  "none"         => nil,
  "arrived"      => "\xB5\x02\x00",
  "disconnected" => "\x05\x04\x00",
  "working"      => "\x60\x01\x02",
  "notWorking"   => "\x60\x01\x01",
  "other"        => "\x6E\x00\x00",
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
          ticker = SilentTicker.new
          drb = ScriptedDrb.new(traffic)
          link = StackChan::Robot::LinkLoop.new(
            port: port, ticker: ticker,
            on_packet: ->(packet) { peripheral.packet_callback(packet) },
            clock: -> { time },
            drb: drb,
            remote: ScriptedSpeakerRemote.new(-> { played ? (time += played; true) : nil }),
            release_after: release_after
          )
          peripheral = ScriptedPeripheral.new(link)
          link.instance_variable_set(:@active_at, age && now - age)
          link.tick
          note_state(LOOP_STATE, link)
          rows << "(#{opt(release)}, ⟨#{now}, .#{name}, #{bool(traffic)}, #{opt(played)}⟩, #{opt(age && now - age)}, " \
                  "#{opt(link.instance_variable_get(:@active_at))}, #{port.cuts}, #{peripheral.advertised}, #{drb.resets}, " \
                  "#{strings_of(port.waits)}, #{port.popped}, #{strings_of(ticker.seen)})"
        end
      end
    end
  end
end

class DisplaySpy
  attr_reader :face, :text, :opened

  def initialize
    @face = false
    @text = false
    @opened = false
  end

  def draw_rect(_x, y, _w, _h, _color, fill: false)
    @face = true unless y == StackChan::Robot::Dispatcher::SUBTITLE_BAND_Y
  end

  def draw_line(_x1, _y1, _x2, _y2, _color)
    @face = true
  end

  def draw_ellipse(_x, _y, _rx, _ry, _color, fill: false)
    @face = true
    @opened = true
  end

  def draw_text(_x, _y, _text, font: nil, fg: nil, bg: nil)
    @text = true
  end
end

class LedSpy
  attr_reader :lit, :calls

  def initialize
    @lit = false
    @calls = []
  end

  def animate_side(side, r, g, b, mode)
    @lit = true
    @calls << ".animate \"#{side}\" #{r} #{g} #{b} \"#{mode}\""
  end

  def flash_side(side, r, g, b, ms)
    @lit = true
    @calls << ".flash \"#{side}\" #{r} #{g} #{b} #{ms}"
  end

  def tick(_now)
  end
end

class ServoSpy
  attr_reader :writes, :torque

  def initialize(zero)
    @zero = zero
    @writes = []
    @torque = false
  end

  def write_pos(pos, time_ms:, speed:)
    @writes << pos
  end

  def read_pos
    @zero
  end

  def enable_torque(_on)
    @torque = true
  end
end

class LineSink
  attr_reader :lines

  def initialize
    @lines = []
  end

  def write(line)
    @lines << line
  end
end

FRAME_CLASSES = [
  ["F", ["1", "9"]], ["L", ["1", "2"]], ["R", ["0", "255", "256", "x"]], ["G", ["255", "256"]], ["B", ["255", "x"]],
  ["S", ["B", "X"]], ["M", ["s", "x"]], ["text", ["hi"]], ["YL", ["0", "100", "101", "x"]], ["YR", ["100", "101"]],
  ["PU", ["100", "x"]], ["T", ["65535", "65536"]], ["V", ["0", "x"]], ["torque", ["on", "off", "x"]],
  ["selftest", ["run", "x"]], ["read", ["pos", "x"]], ["other", ["1"]]
]
HANDLER_CLASSES = [["glow", ["1"]], ["dim", ["1"]]]

def singles(classes)
  out = []
  classes.each { |k, vs| vs.each { |v| out << [[k, v]] } }
  out
end

def pairs_from(classes)
  out = []
  classes.each_with_index do |(k, vs), i|
    vs.each do |v|
      classes[(i + 1)..].each { |k2, vs2| vs2.each { |v2| out << [[k, v], [k2, v2]] } }
    end
  end
  out
end

def app_frames
  frames = singles(FRAME_CLASSES) + pairs_from(FRAME_CLASSES)
  ["1", "2"].each do |l|
    ["B", "X"].each do |side|
      ["s", "x"].each do |mode|
        ["0", "255", "256", "x"].each { |r| frames << [["L", l], ["R", r], ["G", "0"], ["B", "0"], ["S", side], ["M", mode]] }
      end
    end
  end
  ["0", "100", "101", "x"].each { |yl| ["100", "x"].each { |pu| ["65535", "65536"].each { |t| frames << [["YL", yl], ["PU", pu], ["T", t]] } } }
  frames
end

def handler_frames
  singles(HANDLER_CLASSES) + pairs_from(HANDLER_CLASSES + [["F", ["1", "9"]], ["other", ["1"]]])
end

def run_frame(robot, handlers, frame)
  display = DisplaySpy.new
  led = LedSpy.new
  yaw = ServoSpy.new(StackChan::Robot::Head::SERVO_YAW_ZERO)
  pitch = ServoSpy.new(StackChan::Robot::Head::SERVO_PITCH_ZERO)
  sink = LineSink.new
  calls = [0]
  table = {}
  handlers.each { |name, ok| table[name] = ->(_r, _v) { calls[0] += 1; ok } }
  dispatcher = StackChan::Robot::Dispatcher.new(display: display, led: led, stdout: sink,
                                                head: StackChan::Robot::Head.new(yaw, pitch),
                                                faces: robot.faces, face_index: robot.face_index, frame_handlers: table)
  hash = {}
  frame.each { |k, v| hash[k] = v }
  dispatcher.handle(hash)
  [sink.lines[0].to_s.chomp, display.face, led.lit, display.text, !(yaw.writes + pitch.writes).empty?,
   yaw.torque || pitch.torque, calls[0]]
end

def frame_term(frame)
  "[#{frame.map { |k, v| "(\"#{k}\", \"#{v}\")" }.join(", ")}]"
end

def outcome_term(o)
  "⟨\"#{o[0]}\", #{bool(o[1])}, #{bool(o[2])}, #{bool(o[3])}, #{bool(o[4])}, #{bool(o[5])}, #{o[6]}⟩"
end

def head_rows(robot, rows)
  m = 0
  while m <= 100
    raws = ["YL", "YR", "PU"].map do |key|
      yaw = ServoSpy.new(StackChan::Robot::Head::SERVO_YAW_ZERO)
      pitch = ServoSpy.new(StackChan::Robot::Head::SERVO_PITCH_ZERO)
      dispatcher = StackChan::Robot::Dispatcher.new(display: DisplaySpy.new, led: LedSpy.new, stdout: LineSink.new,
                                                    head: StackChan::Robot::Head.new(yaw, pitch),
                                                    faces: robot.faces, face_index: robot.face_index)
      dispatcher.handle({ key => m.to_s })
      (key == "PU" ? pitch.writes : yaw.writes)[0]
    end
    rows << "(#{m}, #{raws[0]}, #{raws[1]}, #{raws[2]})"
    m += 1
  end
end

class GateFront
  def hello(text)
    [text == "ours", "ours"]
  end

  def face(_id)
    "ok"
  end
end

def gate_request(name, args)
  w = DRbBle::Writer.new
  DRb::DRbMessage.new(w).send_request(nil, name, args, nil)
  w.out
end

def gate_answer(responder, name, args)
  out = responder.feed(gate_request(name, args))
  return false if out.empty?
  DRb::DRbMessage.new(DRbBle::Reader.new(out)).recv_reply[0]
end

def gate_rows(rows)
  [false, true].each do |opened|
    %w[helloOurs helloTheirs call reset garbage].each do |event|
      responder = DRbBle::Responder.new(GateFront.new, allow: [:hello, :face], gate: :hello)
      gate_answer(responder, :hello, ["ours"]) if opened
      answered = case event
                 when "helloOurs" then gate_answer(responder, :hello, ["ours"])
                 when "helloTheirs" then gate_answer(responder, :hello, ["theirs"])
                 when "call" then gate_answer(responder, :face, [1])
                 when "reset" then (responder.reset; false)
                 else (responder.feed("\x00\x00\x00\x01Z"); false)
                 end
      note_state(GATE_STATE, responder)
      after = gate_answer(responder, :face, [1])
      rows << "(#{bool(opened)}, .#{event}, #{bool(answered)}, #{bool(after)})"
    end
  end
end

class StubRadio
  attr_accessor :on_notification, :on_disconnect
end

class RobotEnd
  attr_reader :sent

  def initialize(remote)
    @remote = remote
    @sent = []
  end

  def hello(text)
    @remote.hello(text)
  end

  def command(hash)
    lines = @remote.command(hash)
    @sent << [hash.keys, lines[0].to_s.chomp]
    lines
  end

  def touches
    @remote.touches
  end

  def audio_begin(n)
    @remote.audio_begin(n)
  end

  def audio_chunk(bytes)
    @remote.audio_chunk(bytes)
  end

  def audio_play
    @remote.audio_play
  end

  def audio_done
    @remote.perform_audio_play
    @remote.audio_done
  end
end

class OtherRobot
  def hello(_text)
    [false, "faces=0:other"]
  end
end

class SilentRobot
end

def robot_remote(robot, head: nil)
  head ||= StackChan::Robot::Head.new(ServoSpy.new(StackChan::Robot::Head::SERVO_YAW_ZERO),
                                      ServoSpy.new(StackChan::Robot::Head::SERVO_PITCH_ZERO))
  dispatcher = StackChan::Robot::Dispatcher.new(display: DisplaySpy.new, led: LedSpy.new, stdout: LineSink.new,
                                                head: head, faces: robot.faces, face_index: robot.face_index,
                                                frame_handlers: robot.frame_handlers)
  StackChan::Robot::Remote.new(dispatcher)
end

class RecordingCentral < StackChan::Controller::Central
  def initialize(robot)
    super(radio: StubRadio.new, log_fn: ->(_line) {})
    @robot_end = RobotEnd.new(robot_remote(robot))
    @connected = true
  end

  def remote
    @robot_end
  end

  def sent
    @robot_end.sent
  end
end

def agree_rows(robot)
  rows = []
  [["same", RobotEnd.new(robot_remote(robot))], ["different", OtherRobot.new], ["none", SilentRobot.new]].each do |name, front|
    central = RecordingCentral.new(robot)
    central.instance_variable_set(:@robot_end, front)
    result = begin
      central.__send__(:agree)
      "ok"
    rescue StackChan::Controller::ContractMismatch
      "mismatch"
    end
    rows << "(\"#{name}\", \"#{result}\", #{bool(central.connected?)})"
  end
  rows
end

class FixedServo < ServoSpy
  def initialize(pos)
    super(0)
    @pos = pos
  end

  def read_pos
    @pos
  end
end

def reading_rows(robot)
  rows = []
  [nil, 0, 482, 1023].each do |yaw|
    [nil, 0, 633, 1023].each do |pitch|
      sink = LineSink.new
      dispatcher = StackChan::Robot::Dispatcher.new(display: DisplaySpy.new, led: LedSpy.new, stdout: sink,
                                                    head: StackChan::Robot::Head.new(FixedServo.new(yaw), FixedServo.new(pitch)),
                                                    faces: robot.faces, face_index: robot.face_index)
      dispatcher.handle({ "read" => "pos" })
      parsed = StackChan::Controller::Calibration.parse_raw_detail(sink.lines[1])
      rows << "(#{opt(yaw)}, #{opt(pitch)}, #{opt(parsed[:yaw_raw])}, #{opt(parsed[:pitch_raw])})"
    end
  end
  rows
end

def alias_rows(robot)
  calls = [
    ["face 1", ->(r) { r.face(1) }, { "F" => 1 }], ["face 9", ->(r) { r.face(9) }, { "F" => 9 }],
    ["text", ->(r) { r.text("hi") }, { "text" => "hi" }],
    ["torque true", ->(r) { r.torque(true) }, { "torque" => "on" }],
    ["torque on", ->(r) { r.torque("on") }, { "torque" => "on" }],
    ["torque false", ->(r) { r.torque(false) }, { "torque" => "off" }],
    ["torque off", ->(r) { r.torque("off") }, { "torque" => "off" }],
    ["read_pos", ->(r) { r.read_pos }, { "read" => "pos" }],
    ["selftest", ->(r) { r.selftest }, { "selftest" => "run" }],
    ["servo", ->(r) { r.servo({ "YL" => "50" }) }, { "YL" => "50" }],
    ["led", ->(r) { r.led({ "L" => "1", "S" => "B", "M" => "s" }) }, { "L" => "1", "S" => "B", "M" => "s" }],
  ]
  calls.map do |name, call, frame|
    called = call.call(robot_remote(robot)).map(&:chomp)
    direct = robot_remote(robot).command(frame).map(&:chomp)
    "(\"#{name}\", #{strings(called)}, #{strings(direct)})"
  end
end

class DirectEngine
  attr_reader :reply_handlers

  def initialize(handlers)
    @reply_handlers = handlers
  end

  def unlocked
    yield
  end
end

class StubVoice
  def synthesize(_text, _gain = nil, _rate = nil)
    "\xFF" * 800
  end

  def respond(_text, _state)
    "やあ, <ねえ>"
  end
end

def every_led
  out = []
  %w[left right both].each do |side|
    StackChan::Controller::SendBuilder::LED_COLORS.keys.each do |color|
      Stackchan::BLE::FrameCodec::MODE_TO_CHAR.keys.each { |mode| out << [side, color.to_s, mode.to_s] }
    end
  end
  out
end

def face_words
  Stackchan::BLE::FrameCodec::FACE_INDICES.keys.map { |name| [name.to_s] }
end

INPUTS = {
  "mac" => {
    face: face_words,
    led: every_led,
    servo: [["--yaw-left", "0"], ["--yaw-left", "100", "--pitch-up", "100", "--time", "65535"],
            ["--yaw-right", "100", "--velocity", "65535"], ["--pitch-up", "0", "--time", "0"]],
    torque: [["on"], ["off"]],
    say: [["やあ"]],
    chat: [["やあ"], ["--no-speak", "やあ"]],
    demo: [["--duration", "2.4"]],
  },
  "ios" => { subtitle: [["やあ", "ねえ"]] },
  "watchos" => { face: [[]] + face_words },
}

def app_rows(robot, rows)
  %w[mac ios watchos].each do |name|
    load "#{REPO}/apps/#{name}/app.rb"
    app = App
    Object.send(:remove_const, :App)
    app.declared.keys.each do |action|
      ACTIONS << "(\"#{name}\", \"#{action}\")"
      entry = app.declared[action]
      INPUTS[name].fetch(action, [[]]).each do |words|
        central = RecordingCentral.new(robot)
        session = StackChan::Controller::Session.new(central: central, engine: DirectEngine.new(app.reply_handlers),
                                                     voice: StubVoice.new, log: ->(_line) {})
        begin
          entry[:blk].call(session, StackChan::Controller::Args.new(words, flags: entry[:flags]))
        rescue StackChan::Controller::DeviceError
          nil
        end
        central.sent.each do |keys, reply|
          rows << "(\"#{name}\", \"#{action}\", \"#{words.join(" ")}\", #{strings(keys)}, \"#{reply}\")"
        end
      end
    end
  end
  central = RecordingCentral.new(robot)
  session = StackChan::Controller::Session.new(central: central, engine: DirectEngine.new([]), voice: nil, log: ->(_line) {})
  session.torque(false)
  3.times { session.read_pos }
  session.torque(true)
  session.speak_audio("\xFF" * 4096)
  central.sent.each { |keys, reply| rows << "(\"engine\", \"calibrate\", \"\", #{strings(keys)}, \"#{reply}\")" }
end

def face_name(robot, face)
  robot.faces.keys.each { |name| return name.to_s if robot.faces[name].equal?(face) }
  "?"
end

def face_rows(robot, rows)
  events = [["close", nil], ["reopen", nil], ["torqueOn", { "torque" => "on" }], ["torqueOff", { "torque" => "off" }]]
  robot.face_index.keys.each { |index| events << ["show \"#{index}\"", { "F" => index }] }
  events << ["show \"9\"", { "F" => "9" }]
  robot.faces.keys.each do |name|
    [false, true].each do |waiting|
      events.each do |event, frame|
        display = DisplaySpy.new
        dispatcher = StackChan::Robot::Dispatcher.new(display: display, led: LedSpy.new, stdout: LineSink.new,
                                                      head: StackChan::Robot::Head.new(ServoSpy.new(0), ServoSpy.new(0)),
                                                      faces: robot.faces, face_index: robot.face_index)
        ticker = StackChan::Robot::Ticker.new(display: display, led: LedSpy.new, touch: nil, dispatcher: dispatcher,
                                              remote: StackChan::Robot::Remote.new(dispatcher))
        ticker.tick(0)
        dispatcher.show_face(name)
        dispatcher.robot_handle.blink(150) if waiting
        display = DisplaySpy.new
        dispatcher.instance_variable_set(:@display, display)
        ticker.instance_variable_set(:@display, display)
        dispatcher.robot_handle.instance_variable_set(:@display, display)
        case event
        when "close" then dispatcher.robot_handle.blink(150)
        when "reopen" then ticker.tick(150)
        else dispatcher.handle(frame)
        end
        note_state(TICKER_STATE, ticker)
        after = !ticker.instance_variable_get(:@open_at).nil?
        rows << "(⟨\"#{name}\", #{bool(waiting)}⟩, .#{event}, ⟨\"#{face_name(robot, dispatcher.current_face)}\", " \
                "#{bool(after)}⟩, #{bool(display.opened)})"
      end
    end
  end
end

def zones_upto(n)
  out = []
  i = 0
  while i < n
    out << i % 3
    i += 1
  end
  out
end

def remote_out(value)
  return ".nothing" if value.nil?
  return ".zones #{strings_of(value)}" if value.is_a?(Array)
  return ".size #{value}" if value.is_a?(Integer)
  ".flag #{bool(value)}"
end

def remote_term(remote)
  "⟨#{strings_of(remote.instance_variable_get(:@touch_queue))}, #{remote.instance_variable_get(:@audio_buf).bytesize}, " \
    "#{bool(remote.instance_variable_get(:@audio_pending))}, #{bool(remote.instance_variable_get(:@audio_done))}⟩"
end

def remote_rows(rows)
  events = [["touch 1", ->(r) { r.push_touch(1); nil }], ["take", ->(r) { r.touches }],
            ["begin", ->(r) { r.audio_begin(4) }], ["chunk 2", ->(r) { r.audio_chunk("\x01\x02") }],
            ["play", ->(r) { r.audio_play }], ["perform", ->(r) { r.perform_audio_play; nil }],
            ["done", ->(r) { r.audio_done }]]
  [0, 1, 15, 16].each do |queued|
    [0, 3].each do |buffered|
      [false, true].each do |pending|
        [false, true].each do |finished|
          events.each do |event, call|
            remote = StackChan::Robot::Remote.new(nil)
            remote.instance_variable_set(:@touch_queue, zones_upto(queued))
            remote.instance_variable_set(:@audio_buf, "\x01" * buffered)
            remote.instance_variable_set(:@audio_pending, pending)
            remote.instance_variable_set(:@audio_done, finished)
            before = remote_term(remote)
            out = call.call(remote)
            note_state(REMOTE_STATE, remote)
            rows << "(#{before}, .#{event}, #{remote_term(remote)}, #{remote_out(out)})"
          end
        end
      end
    end
  end
end

class TouchSensor
  def initialize(zone)
    @zone = zone
  end

  def poll
    zone = @zone
    @zone = nil
    zone
  end
end

def touch_rows(robot, rows)
  [nil, 951, 950].each do |last|
    [nil, 0, 1].each do |zone|
      [false, true].each do |fails|
        reacted = []
        handlers = { 0 => ->(_r) { reacted << 0; raise "reaction failed" if fails } }
        display = DisplaySpy.new
        dispatcher = StackChan::Robot::Dispatcher.new(display: display, led: LedSpy.new, stdout: LineSink.new,
                                                      faces: robot.faces, face_index: robot.face_index)
        remote = StackChan::Robot::Remote.new(dispatcher)
        ticker = StackChan::Robot::Ticker.new(display: display, led: LedSpy.new, touch: TouchSensor.new(zone),
                                              dispatcher: dispatcher, remote: remote, touch_handlers: handlers)
        ticker.instance_variable_set(:@touch_at, last)
        ticker.tick(1000)
        rows << "(#{opt(last)}, ⟨1000, #{opt(zone)}, #{bool(fails)}⟩, " \
                "⟨#{opt(ticker.instance_variable_get(:@touch_at))}, #{strings_of(reacted)}, #{strings_of(remote.touches)}⟩)"
      end
    end
  end
end

def handle_calls(robot)
  calls = []
  (robot.faces.keys.map(&:to_s) + ["nope"]).each { |name| calls << [".face \"#{name}\"", ->(h) { h.face(name.to_sym) }] }
  %w[left right both].each do |side|
    %w[solid blink].each do |mode|
      [nil, 300].each do |flash|
        calls << [".led \"#{side}\" 1 2 3 \"#{mode}\" #{opt(flash)}",
                  ->(h) { h.led(side.to_sym, [1, 2, 3], mode: mode.to_sym, flash: flash) }]
      end
    end
  end
  calls << [".head (some 50) none (some 30) 400", ->(h) { h.head(yaw_left: 50, pitch_up: 30, time: 400) }]
  calls << [".head none (some 60) none 0", ->(h) { h.head(yaw_right: 60) }]
  calls << [".text \"hi\"", ->(h) { h.text("hi") }]
  calls
end

def handle_rows(robot, rows)
  handle_calls(robot).each do |call, act|
    display = DisplaySpy.new
    led = LedSpy.new
    dispatcher = StackChan::Robot::Dispatcher.new(display: display, led: led, stdout: LineSink.new,
                                                  faces: robot.faces, face_index: robot.face_index)
    effects = []
    dispatcher.define_singleton_method(:move_head) do |yl, yr, pu, time, velocity|
      effects << ".move #{opt(yl)} #{opt(yr)} #{opt(pu)} #{time} #{velocity}"
      true
    end
    dispatcher.define_singleton_method(:draw_subtitle) do |s|
      effects << ".subtitle \"#{s}\""
      true
    end
    act.call(dispatcher.robot_handle)
    effects << ".face \"#{face_name(robot, dispatcher.current_face)}\" #{bool(display.face)}" if call.start_with?(".face")
    rows << "(#{call}, [#{(effects + led.calls).join(", ")}])"
  end
end

def contract_keys(contract)
  contract.split(";").each { |part| return part[5, part.size - 5].split(",") if part.start_with?("keys=") }
  []
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

def robot_app
  robot = nil
  StackChan.singleton_class.alias_method(:declare_robot, :robot)
  StackChan.define_singleton_method(:robot) do |&block|
    robot = declare_robot(&block)
    robot
  end
  load "#{REPO}/apps/robot/app.rb"
  robot
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

def strings_of(numbers)
  "[#{numbers.join(", ")}]"
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

robot = robot_app
release_after = robot.release_after
keepalive = StackChan::Controller::Link.new(central: nil, log: nil).instance_variable_get(:@keepalive_ms)
counts = []

facts("Link", "Link") do |file|
  file.write("def keepalive : Nat := #{keepalive}\n\n")
  counts << table(file, "observedTicks", "(Option Nat × TickIn × Link × Link × List Call × Nat)") do |rows|
    link_tick_rows(rows, 10_000, keepalive)
    link_tick_rows(rows, nil, keepalive)
  end
  counts << table(file, "observedActs", "(ActIn × Link × ActOut × Nat × Bool × Nat × Option Nat)") { |rows| link_act_rows(rows) }
  counts << table(file, "observedListens", "(Link × Link)") { |rows| link_listen_rows(rows) }
  fresh = StackChan::Controller::Link.new(central: nil, hold: 10_000, log: nil)
  file.write("def fresh : String := \"#{fresh.status.keys.map { |k| "#{k}=#{fresh.status[k].nil? ? "none" : fresh.status[k]}" }.join(" ")} touches=#{fresh.touches.size}\"\n\n")
  file.write("def state : List String := #{strings(LINK_STATE)}\n\n")
end

facts("LinkLoop", "LinkLoop") do |file|
  file.write("def tickMs : Nat := #{StackChan::Robot::LinkLoop::TICK_MS}\n\n")
  counts << table(file, "observedTicks", "(Option Nat × TickIn × Option Nat × Option Nat × Nat × Nat × Nat × List Nat × Nat × List Nat)") do |rows|
    link_loop_rows(rows, release_after)
    link_loop_rows(rows, nil)
  end
  file.write("def state : List String := #{strings(LOOP_STATE)}\n\n")
end

facts("Frame", "Frame") do |file|
  faces = robot.face_index.keys.select { |index| robot.faces[robot.face_index[index]] }
  file.write("def appTables : Tables := ⟨#{strings(faces)}, [], true⟩\n\n")
  file.write("def handlerTables : Tables := ⟨#{strings(faces)}, [(\"glow\", true), (\"dim\", false)], true⟩\n\n")
  counts << table(file, "observedApp", "(Frame × Outcome)") do |rows|
    app_frames.each { |frame| rows << "(#{frame_term(frame)}, #{outcome_term(run_frame(robot, {}, frame))})" }
  end
  counts << table(file, "observedHandlers", "(Frame × Outcome)") do |rows|
    handler_frames.each do |frame|
      rows << "(#{frame_term(frame)}, #{outcome_term(run_frame(robot, { "glow" => true, "dim" => false }, frame))})"
    end
  end
  counts << table(file, "observedHead", "(Nat × Int × Int × Int)") { |rows| head_rows(robot, rows) }
end

facts("Contract", "Contract") do |file|
  dispatcher = StackChan::Robot::Dispatcher.new(display: DisplaySpy.new, led: LedSpy.new, faces: robot.faces,
                                                face_index: robot.face_index)
  file.write("def robot : String := \"#{StackChan::Robot::Remote.new(dispatcher).contract}\"\n\n")
  file.write("def controller : String := \"#{StackChan::Controller::Central.contract}\"\n\n")
  file.write("def engineKeys : List String := #{strings(StackChan::Robot::Dispatcher::FRAME_KEYS)}\n\n")
  file.write("def systemKeys : List String := #{strings(StackChan::Robot::Dispatcher::SYSTEM_KEYS)}\n\n")
  counts << table(file, "observedGate", "(Bool × GateEvent × Bool × Bool)") { |rows| gate_rows(rows) }
  file.write("def gateState : List String := #{strings(GATE_STATE)}\n\n")
  remote = StackChan::Robot::Remote.new(dispatcher)
  file.write("def contractKeys : List String := #{strings(contract_keys(remote.contract))}\n\n")
  hellos = [StackChan::Controller::Central.contract, "#{remote.contract};extra", ""].map do |text|
    "(#{text.inspect}, #{bool(remote.hello(text)[0])})"
  end
  file.write("def helloAnswers : List (String × Bool) := [#{hellos.join(", ")}]\n\n")
  counts << table(file, "sent", "(String × String × String × List String × String)") { |rows| app_rows(robot, rows) }
  file.write("def actions : List (String × String) := [#{ACTIONS.join(", ")}]\n\n")
  file.write("def agreements : List (String × String × Bool) := [#{agree_rows(robot).join(", ")}]\n\n")
  file.write("def readings : List (Option Nat × Option Nat × Option Nat × Option Nat) := [#{reading_rows(robot).join(", ")}]\n\n")
end

facts("Touch", "Touch") do |file|
  counts << table(file, "observedPolls", "(Option Nat × Poll × Read)") { |rows| touch_rows(robot, rows) }
  counts << table(file, "observedCalls", "(Call × List Effect)") { |rows| handle_rows(robot, rows) }
end

facts("Remote", "Remote") do |file|
  counts << table(file, "observed", "(State × Event × State × Out)") { |rows| remote_rows(rows) }
  file.write("def aliases : List (String × List String × List String) := [#{alias_rows(robot).join(", ")}]\n\n")
  file.write("def state : List String := #{strings(REMOTE_STATE)}\n\n")
end

facts("Face", "Face") do |file|
  index = robot.face_index.keys.map { |i| "(\"#{i}\", \"#{robot.face_index[i]}\")" }
  opened = robot.faces.keys.select { |name| robot.faces[name].eyes == :open }.map(&:to_s)
  file.write("def faces : Faces := ⟨[#{index.join(", ")}], #{strings(opened)}⟩\n\n")
  first = StackChan::Robot::Dispatcher.new(display: DisplaySpy.new, led: LedSpy.new, faces: robot.faces,
                                           face_index: robot.face_index)
  file.write("def coldBoot : String := \"#{face_name(robot, first.current_face)}\"\n\n")
  file.write("def names : List String := #{strings(robot.faces.keys.map(&:to_s))}\n\n")
  counts << table(file, "observed", "(Look × FaceEvent × Look × Bool)") { |rows| face_rows(robot, rows) }
  file.write("def tickerState : List String := #{strings(TICKER_STATE)}\n\n")
end

facts("Apps", nil) do |file|
  file.write("structure App where\n  name : String\n  hold : Option Nat\n  touchHandlers : Nat\n  periodic : Nat\n  tickMs : Nat\n" \
             "  deriving DecidableEq, Repr\n\n")
  file.write("def controllers : List App := [#{controller_apps.join(", ")}]\n\n")
  file.write("def releaseAfter : Option Nat := #{opt(release_after)}\n\n")
  file.write("def ackTimeoutMs : Nat := #{StackChan::Controller::Central::ACK_TIMEOUT_MS}\n\n")
  file.write("def acceptanceSteps : List String := #{strings(acceptance_steps)}\n\n")
end

puts "facts: #{counts.join(" / ")} rows"
