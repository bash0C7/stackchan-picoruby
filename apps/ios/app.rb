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

  %w[neutral smile joy surprised sad angry].each do |name|
    c.action(name.to_sym, label: name) { |s, _a| show.call(s, name) }
  end

  %w[red green blue yellow cyan magenta white].each do |color|
    c.action("led_#{color}".to_sym, label: "LED #{color}") do |s, _a|
      s.led(:both, color.to_sym, mode: :solid)
      "OK led=both/#{color}/solid"
    end
  end

  c.action(:led_off, label: "LED off") do |s, _a|
    s.led(:both, :off, mode: :off)
    "OK led=both/off/off"
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
