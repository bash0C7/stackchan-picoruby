# frozen_string_literal: true

module Stackchan
  module Demo
    DEFAULT_DURATION_S = 10.0
    INTRO_LINE         = "こんにちは、ぼくスタックチャンだよ"
    OUTRO_LINE         = "タッチしてみて"
    FACES              = %w[joy smile surprised joy smile].freeze
    COLORS             = %i[red yellow green cyan blue magenta white].freeze
    MODES              = %i[solid blink breathing].freeze
    SERVO_POSES        = [
      { yaw_left:  60, pitch_up: 30, time_ms: 500 },
      { yaw_right: 60, pitch_up: 30, time_ms: 500 },
      { yaw_left:   0, pitch_up: 60, time_ms: 500 },
      { yaw_right: 60, pitch_up:  0, time_ms: 500 },
      { yaw_left:  60, pitch_up:  0, time_ms: 500 },
    ].freeze
    STEP_INTERVAL_S = 0.7

    # Drives a fixed 10-second introductory performance:
    # opening line + cycling face/LED/servo + closing line that invites a touch.
    # The caller can decide to chain into `touch listen --react` afterwards.
    class Runner
      def initialize(daemon, stdout: $stdout)
        @daemon = daemon
        @stdout = stdout
      end

      def run(duration: DEFAULT_DURATION_S, intro: INTRO_LINE, outro: OUTRO_LINE)
        @stdout.puts "[demo] start (#{duration}s) — say + face + servo + LED in motion"
        @daemon.say(intro)
        sleep 0.2
        deadline = Time.now + duration
        i = 0
        while Time.now < deadline
          @daemon.face(FACES[i % FACES.size])
          @daemon.led(side: :both, color: COLORS[i % COLORS.size], mode: MODES[i % MODES.size])
          pose = SERVO_POSES[i % SERVO_POSES.size]
          @daemon.servo(**pose)
          sleep STEP_INTERVAL_S
          i += 1
        end
        @daemon.face("neutral")
        @daemon.led(side: :both, color: :off, mode: :off)
        @daemon.servo(yaw_left: 0, pitch_up: 0, time_ms: 500)
        sleep 0.5
        @daemon.say(outro)
        @stdout.puts "[demo] done — caller can `touch listen --react` to wait for a touch."
      end
    end
  end
end
