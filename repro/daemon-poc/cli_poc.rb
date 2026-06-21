# PicoRuby CLI client PoC — connects to the PicoRuby daemon over picoruby-drb
# TCP loopback and drives verbs, then reads back state + the frames the daemon
# built. Mirrors how the real `stackchan <verb>` CLI talks to the daemon.
#   picoruby cli_poc.rb [port]
port = (ARGV[0] || "8788").to_i
require "drb"

def out(s); $stdout.write(s + "\n"); $stdout.flush; end

DRb.start_service
d = DRb::DRbObject.new_with_uri("druby://127.0.0.1:#{port}")

out "FACE=" + d.face(:joy)
out "LED="  + d.led("left", "red", "blink")
out "SAY="  + d.say("こんにちは、テストです")
out "STATUS1 keepalive_ticks=#{d.status[:keepalive_ticks]}"
# Idle between calls — daemon's server task blocks on accept; the keepalive
# Task should advance during this window. Proves no permanent starvation.
sleep 1
st = d.status
out "STATUS2 last_face=#{st[:last_face]} last_say=#{st[:last_say]} last_action=#{st[:last_action]} keepalive_ticks=#{st[:keepalive_ticks]}"
out "FRAMES=" + d.sent_frames.inspect
out "CLI_OK"
