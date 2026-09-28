App = StackChan.controller do |c|
  c.hold 10_000

  c.action(:face) do |s, a|
    s.face(a[0].to_sym)
    "OK face=#{a[0]}"
  end

  c.action(:led) do |s, a|
    next "led: side color mode required" if a.size < 3
    s.led(a[0].to_sym, a[1].to_sym, mode: a[2].to_sym)
    "OK led=#{a[0]}/#{a[1]}/#{a[2]}"
  end

  c.action(:servo) do |s, a|
    detail = s.servo(yaw_left: a.int("yaw-left"), yaw_right: a.int("yaw-right"), pitch_up: a.int("pitch-up"),
                     time_ms: a.int("time"), velocity: a.int("velocity"))
    "servo detail=#{detail.inspect}"
  end

  c.action(:torque) do |s, a|
    on = a[0] == "on"
    s.torque(on)
    "OK torque=#{on ? 'on' : 'off'}"
  end

  c.action(:selftest) do |s, _a|
    s.selftest
    "OK selftest"
  end

  c.action(:say) do |s, a|
    s.say(a.text, gain: a.float("gain"), rate: a.int("rate"))
  end

  c.action(:chat, flags: ["no-speak"]) do |s, a|
    reply = s.chat(a.text, speak: !a.flag?("no-speak"))
    reply ? "reply=#{reply}" : "reply=(none)"
  end

  c.action(:demo) do |s, a|
    rate = 250
    faces = [:joy, :smile, :surprised, :joy, :smile]
    colors = [[:red, :blue], [:yellow, :magenta], [:green, :cyan], [:cyan, :red], [:magenta, :yellow], [:white, :green]]
    modes = [[:blink, :breathing], [:breathing, :solid], [:solid, :blink]]
    poses = [
      { yaw_left: 60, pitch_up: 30 },
      { yaw_right: 60, pitch_up: 30 },
      { yaw_left: 0, pitch_up: 60 },
      { yaw_right: 60, pitch_up: 0 },
      { yaw_left: 60, pitch_up: 0 },
    ]
    step_ms = 1200
    steps = ((a.float("duration") || 10.0) / 1.2).to_i
    s.led(:left, :red, mode: :blink)
    s.led(:right, :blue, mode: :breathing)
    sleep_ms 1500
    s.say("ぼくスタックチャン！", rate: rate)
    sleep_ms 500
    i = 0
    while i < steps
      s.face(faces[i % faces.size])
      lc, rc = colors[i % colors.size]
      lm, rm = modes[i % modes.size]
      s.led(:left, lc, mode: lm)
      s.led(:right, rc, mode: rm)
      pose = poses[i % poses.size]
      s.servo(yaw_left: pose[:yaw_left], yaw_right: pose[:yaw_right], pitch_up: pose[:pitch_up], time_ms: 800)
      sleep_ms step_ms
      i += 1
    end
    s.face(:neutral)
    s.led(:both, :off, mode: :off)
    s.servo(yaw_left: 0, pitch_up: 0, time_ms: 800)
    sleep_ms 700
    s.say("タッチしてみて", rate: rate)
    ["[demo] start", "[demo] done"]
  end

  c.on_reply { |s, text| s.text(text, face: :smile) }
end
