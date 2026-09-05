#!/usr/bin/env ruby
# Idle-loop demo: random LED colors continuously, occasional random head
# moves and face changes (kept infrequent so the servos don't wear/overheat).
# No AI/chat involved — just `stackchan` CLI calls with randomized args.
#
#   tools/ambient_demo.rb
#
# Ctrl-C (or SIGTERM) stops the loop and leaves the robot in a neutral rest
# state (LEDs off, face neutral, torque off).

STACKCHAN = File.expand_path("../pc/stackchan-pico/bin/stackchan", __dir__)

COLORS = %i[red green blue yellow cyan magenta white].freeze
MODES  = %i[blink breathing solid].freeze
SIDES  = %i[left right both].freeze
FACES  = %i[smile joy].freeze

LED_INTERVAL_RANGE  = (4..9).freeze     # seconds — frequent color changes
FACE_INTERVAL_RANGE = (12..25).freeze   # seconds
MOVE_INTERVAL_RANGE = (30..70).freeze   # seconds — infrequent on purpose

def run(*args)
  ok = system(STACKCHAN, *args.map(&:to_s))
  puts "[#{Time.now.strftime('%H:%M:%S')}] stackchan #{args.join(' ')} #{ok ? 'OK' : 'FAILED'}"
  $stdout.flush
  ok
end

def wait_until_connected
  loop do
    out = `#{STACKCHAN} status`
    return true if out.include?("ble_connected: true") || out.include?("ble_connected=>true")
    puts "[#{Time.now.strftime('%H:%M:%S')}] waiting for BLE connection..."
    $stdout.flush
    sleep 3
  end
end

def random_led
  side = SIDES.sample
  color = COLORS.sample
  mode = MODES.sample
  run("led", side, color, mode)
end

def random_face
  run("face", FACES.sample)
end

def random_move
  yaw_key = %w[--yaw-left --yaw-right].sample
  args = [yaw_key, rand(0..100), "--pitch-up", rand(0..100), "--time", rand(600..1200)]
  run("servo", *args)
end

def rest_state
  run("led", :both, :off, :off)
  run("face", :neutral)
  run("servo", "--yaw-left", 0, "--pitch-up", 0, "--time", 800)
  run("torque", "off")
end

wait_until_connected
run("torque", "on")

trap("INT")  { rest_state; exit 0 }
trap("TERM") { rest_state; exit 0 }

now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
next_led  = now
next_face = now
next_move = now

loop do
  now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  if now >= next_led
    random_led
    next_led = now + rand(LED_INTERVAL_RANGE)
  end
  if now >= next_face
    random_face
    next_face = now + rand(FACE_INTERVAL_RANGE)
  end
  if now >= next_move
    random_move
    next_move = now + rand(MOVE_INTERVAL_RANGE)
  end
  sleep 1
end
