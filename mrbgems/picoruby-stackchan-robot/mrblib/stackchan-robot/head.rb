module StackChan
  class Robot
    class Head
      YAW_RANGE_RAW   = 300
      PITCH_RANGE_RAW = 296

      SERVO_YAW_ZERO   = 482
      SERVO_PITCH_ZERO = 633

      def initialize(yaw_servo, pitch_servo)
        @yaw   = yaw_servo
        @pitch = pitch_servo
      end

      def apply(yaw_raw: nil, pitch_raw: nil, time_ms: 0, velocity: 0)
        @yaw.write_pos(yaw_raw, time_ms: time_ms, speed: velocity)     if yaw_raw
        @pitch.write_pos(pitch_raw, time_ms: time_ms, speed: velocity) if pitch_raw
      end

      def enable_torque(on)
        @yaw.enable_torque(on)
        @pitch.enable_torque(on)
      end

      def read_actual
        { yaw: @yaw.read_pos, pitch: @pitch.read_pos }
      end

      def read_health
        { yaw: [@yaw.last_read_error, @yaw.last_status], pitch: [@pitch.last_read_error, @pitch.last_status] }
      end

      def selftest
        y0 = SERVO_YAW_ZERO
        [(y0 + 10), (y0 - 10), y0].each do |target|
          @yaw.write_pos(target, time_ms: 50, speed: 0)
          Machine.delay_ms(80)
        end
      end
    end
  end
end
