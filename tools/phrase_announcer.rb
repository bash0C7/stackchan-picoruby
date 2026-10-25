#!/usr/bin/env ruby
# Speaks a random fixed phrase every 30s. Deterministic, no network, no AI.
#
#   tools/phrase_announcer.rb

STACKCHAN  = File.expand_path("../pc/stackchan-pico/bin/stackchan", __dir__)
SAY_GAIN   = "0.175" # midpoint between default 0.05 (too quiet) and 0.3 (clipped)
INTERVAL_S = 30

PHRASES = [
  "こんにちは、ぼくスタックチャン、かわいいよ",
  "ルビーカイギフォローアップにようこそ",
  "本屋さんやスポンサーブースもたのしんでね",
  "頭もなでてみてね",
  "ここはアイブリーのオフィスだよ。すごいね",
].freeze

# Prints msg with a timestamp and flushes stdout.
#: (String msg) -> void
def log(msg)
  puts "[#{Time.now.strftime('%H:%M:%S')}] #{msg}"
  $stdout.flush
end

# Speaks text through the stackchan CLI and logs whether it succeeded.
#: (String text) -> void
def speak(text)
  ok = system(STACKCHAN, "say", text, "--gain", SAY_GAIN)
  log "say #{ok ? 'OK' : 'FAILED'}: #{text}"
end

trap("INT")  { exit 0 }
trap("TERM") { exit 0 }

loop do
  speak(PHRASES.sample)
  sleep INTERVAL_S
end
