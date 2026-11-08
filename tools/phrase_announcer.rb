PHRASES = [
  "こんにちは、ぼくスタックチャン、かわいいよ",
  "ルビーカイギフォローアップにようこそ",
  "本屋さんやスポンサーブースもたのしんでね",
  "頭もなでてみてね",
  "ここはアイブリーのオフィスだよ。すごいね",
]
SAY_GAIN   = "0.175"
INTERVAL_S = 30

if ARGV[0]
  cli = "#{ARGV[0]}/pc/stackchan-pico/bin/stackchan"
  while true
    text = PHRASES[rand(PHRASES.size)]
    io = IO.popen("'#{cli}' say '#{text}' --gain #{SAY_GAIN} 2>&1; echo exit:$?")
    out = io.read
    io.close
    t = Time.now
    puts "[#{format('%02d:%02d:%02d', t.hour, t.min, t.sec)}] say #{out.end_with?("exit:0\n") ? 'OK' : 'FAILED'}: #{text}"
    sleep INTERVAL_S
  end
end
