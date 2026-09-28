App = StackChan.controller do |c|
  c.hold 10_000

  show = lambda do |s, name|
    s.face(name.to_sym)
    "OK face=#{name}"
  end

  turn = lambda do |s, name, pose|
    detail = s.servo(yaw_left: pose[:yaw_left], yaw_right: pose[:yaw_right], pitch_up: pose[:pitch_up], time_ms: 400)
    "OK head=#{name} #{detail.to_s.chomp}"
  end

  c.action(:face, label: "Face") do |s, a|
    next "face: a face name is required" unless a[0]
    show.call(s, a[0])
  end

  %w[neutral smile joy surprised sad angry].each do |name|
    c.action(name.to_sym, label: name) { |s, _a| show.call(s, name) }
  end

  c.action(:led, label: "LED") do |s, a|
    next "led: color [mode] [side] is required" unless a[0]
    mode = a[1] || "solid"
    side = a[2] || "both"
    s.led(side.to_sym, a[0].to_sym, mode: mode.to_sym)
    "OK led=#{side}/#{a[0]}/#{mode}"
  end

  c.action(:left, label: "Left") { |s, _a| turn.call(s, "left", { yaw_left: 40 }) }
  c.action(:center, label: "Center") { |s, _a| turn.call(s, "center", { yaw_left: 0, pitch_up: 0 }) }
  c.action(:right, label: "Right") { |s, _a| turn.call(s, "right", { yaw_right: 40 }) }
  c.action(:up, label: "Up") { |s, _a| turn.call(s, "up", { pitch_up: 30 }) }

  c.action(:subtitle, label: "Subtitle") do |s, a|
    s.text(a.text)
    "OK subtitle=#{a.text}"
  end

  c.action(:selftest, label: "Selftest") do |s, _a|
    "OK selftest detail=#{s.selftest.inspect}"
  end
end
