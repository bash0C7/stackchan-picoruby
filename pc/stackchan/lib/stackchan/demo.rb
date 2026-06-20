# frozen_string_literal: true

module Stackchan
  module Demo
    DEFAULT_DURATION_S = 10.0
    INTRO_LINE         = "こんにちは、ぼくスタックチャンだよ"
    OUTRO_LINE         = "タッチしてみて"
    FACES              = %w[joy smile surprised joy smile].freeze
    # Left/right colour + mode pairs cycled through during the demo.
    # Pairs are deliberately contrasting so the asymmetry is visible at a glance.
    LR_COLOR_PAIRS = [
      [:red,     :blue],
      [:yellow,  :magenta],
      [:green,   :cyan],
      [:cyan,    :red],
      [:magenta, :yellow],
      [:white,   :green],
    ].freeze
    LR_MODE_PAIRS  = [
      [:blink,     :breathing],
      [:breathing, :solid],
      [:solid,     :blink],
    ].freeze
    SERVO_POSES        = [
      { yaw_left:  60, pitch_up: 30, time_ms: 800 },
      { yaw_right: 60, pitch_up: 30, time_ms: 800 },
      { yaw_left:   0, pitch_up: 60, time_ms: 800 },
      { yaw_right: 60, pitch_up:  0, time_ms: 800 },
      { yaw_left:  60, pitch_up:  0, time_ms: 800 },
    ].freeze
    # 1.2s cycle keeps each step visible and gives the device room between
    # heavy frames (the previous 0.7s pace overlapped audio+face redraws and
    # crashed the device mid-demo).
    STEP_INTERVAL_S = 1.2

    # Drives a fixed introductory performance: opening LED animation +
    # intro line + cycling face/LED-L/R/servo + closing line that invites a
    # touch. Caller can chain into `touch listen --react` afterwards.
    class Runner
      def initialize(daemon, stdout: $stdout)
        @daemon = daemon
        @stdout = stdout
      end

      def run(duration: DEFAULT_DURATION_S, intro: INTRO_LINE, outro: OUTRO_LINE)
        @stdout.puts "[demo] start — LED L/R opening → say → cycling → outro"
        # Opening LED animation (左 red blink + 右 blue breathing) gives an
        # immediate visible "demo started" signal before any audio path runs.
        @daemon.led(side: :left,  color: :red,  mode: :blink)
        @daemon.led(side: :right, color: :blue, mode: :breathing)
        sleep 1.5
        @daemon.say(intro)
        sleep 0.5
        deadline = Time.now + duration
        i = 0
        while Time.now < deadline
          @daemon.face(FACES[i % FACES.size])
          left_color,  right_color = LR_COLOR_PAIRS[i % LR_COLOR_PAIRS.size]
          left_mode,   right_mode  = LR_MODE_PAIRS[i % LR_MODE_PAIRS.size]
          @daemon.led(side: :left,  color: left_color,  mode: left_mode)
          @daemon.led(side: :right, color: right_color, mode: right_mode)
          pose = SERVO_POSES[i % SERVO_POSES.size]
          @daemon.servo(**pose)
          sleep STEP_INTERVAL_S
          i += 1
        end
        @daemon.face("neutral")
        @daemon.led(side: :both, color: :off, mode: :off)
        @daemon.servo(yaw_left: 0, pitch_up: 0, time_ms: 800)
        sleep 0.7
        @daemon.say(outro)
        @stdout.puts "[demo] done — caller can `touch listen --react` to wait for a touch."
      end
    end
  end
end
