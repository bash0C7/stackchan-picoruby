App = StackChan.controller do |c|
  c.hold 10_000

  shown = :smile

  c.action(:face, label: "顔をかえる") do |s, a|
    name = a[0] ? a[0].to_sym : (shown == :smile ? :joy : :smile)
    s.face(name)
    shown = name
    "OK face=#{name}"
  end

  c.action(:led_show, label: "LEDを光らせる") do |s, _a|
    [:red, :green, :blue, :yellow, :cyan, :magenta].each do |color|
      s.led(:both, color, mode: :blink)
      sleep_ms 500
    end
    s.led(:both, :off, mode: :off)
    "OK led_show"
  end

  c.action(:head_sweep, label: "ぐるっと") do |s, _a|
    s.servo(yaw_left: 60, time_ms: 500)
    sleep_ms 600
    s.servo(yaw_right: 60, time_ms: 500)
    sleep_ms 600
    s.servo(pitch_up: 40, time_ms: 500)
    sleep_ms 600
    s.servo(yaw_left: 0, pitch_up: 0, time_ms: 400)
    "OK head_sweep"
  end
end
