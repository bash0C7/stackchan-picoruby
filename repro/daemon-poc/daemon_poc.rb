# PicoRuby daemon architecture PoC (sub-project #3 de-risk).
#   picoruby daemon_poc.rb <repo-root> [port]
#
# Proves: a PicoRuby picoruby-drb TCP *server* (the daemon) exposing verb
# methods that build wire frames via the shared gem, with a Task-based
# keepalive running concurrently with the drb accept loop. The real BLE write
# is stubbed by appending the frame to an in-memory log (the gem produces the
# exact bytes the daemon would send). Observes whether the blocking accept loop
# starves the cooperative keepalive Task — the core #3 concurrency question.
root = ARGV[0] || "."
port = (ARGV[1] || "8788").to_i
[
  "stackchan.rb",
  "stackchan/ble/face_table.rb",
  "stackchan/ble/led_color_table.rb",
  "stackchan/ble/hsb_to_rgb.rb",
  "stackchan/ble/frame_codec.rb",
  "stackchan/ble/send_builder.rb",
  "stackchan/ai/frame_text.rb",
].each { |f| load "#{root}/mrbgems/picoruby-stackchan-shared/mrblib/#{f}" }
require "drb"

def log(msg); $stderr.write("[daemon] #{msg}\n"); $stderr.flush; end

# Daemon "front" — the DRb-exposed verb API. Stands in for Stackchan::Daemon.
# Each verb builds a frame with the shared gem and records it (BLE write stub).
class DaemonFront
  def initialize
    @frames = []
    @state  = { last_face: nil, last_say: nil, last_action: nil, keepalive_ticks: 0 }
  end

  def face(name)
    push Stackchan::BLE::FrameCodec.encode_face(face_name: name.to_sym)
    @state[:last_face] = name.to_s
    record(:face)
    "OK face=#{name}"
  end

  def led(side, color, mode)
    b = Stackchan::BLE::SendBuilder.new
    b.led(color.to_sym, side: side.to_sym, mode: mode.to_sym)
    b.to_frames.each { |f| push(f) }
    record(:led)
    "OK led=#{side}/#{color}/#{mode}"
  end

  def say(text)
    push Stackchan::AI::FrameText.build(face_index: nil, text: text)
    @state[:last_say] = text
    record(:say)
    "OK say"
  end

  def status; @state.dup; end
  def sent_frames; @frames.dup; end

  # keepalive Task calls this; bumps a counter so we can prove it ran
  # concurrently with the accept loop.
  def tick_keepalive; @state[:keepalive_ticks] += 1; end

  private

  def push(frame); @frames << frame; log("send_frame #{frame.inspect}"); end
  def record(action); @state[:last_action] = action.to_s; end
end

front = DaemonFront.new
uri = "druby://127.0.0.1:#{port}"
DRb.start_service(uri, front)
log "listening on #{uri}"

# Keepalive Task: in the real daemon this sends an idempotent <read:pos> every
# 7s of inactivity. Here it just bumps a counter every 0.3s so the test can see
# whether it advances while the drb server is blocked on accept().
keepalive = Task.new(name: "keepalive") do
  loop do
    sleep 0.3
    front.tick_keepalive
    log "keepalive tick=#{front.status[:keepalive_ticks]}"
  end
end

# Run the drb accept loop. DRb.thread returns a Task running server.run
# (the blocking accept loop). Keeping the VM alive by joining on it.
server_task = DRb.thread
log "serving"
server_task.join
