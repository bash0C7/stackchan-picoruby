module StackChan
  class Robot
    # The yaw and pitch servo pair. Takes raw servo positions and reads them back.
    class Head
      YAW_RANGE_RAW   = 300
      PITCH_RANGE_RAW = 296

      SERVO_YAW_ZERO   = 482
      SERVO_PITCH_ZERO = 633

      # @rbs @yaw: untyped
      # @rbs @pitch: untyped

      # Stores the yaw and pitch servos.
      #: (untyped yaw_servo, untyped pitch_servo) -> void
      def initialize(yaw_servo, pitch_servo)
        @yaw   = yaw_servo
        @pitch = pitch_servo
      end

      # Writes the given raw positions (nil skips that axis) with time_ms and velocity.
      #: (?yaw_raw: Integer?, ?pitch_raw: Integer?, ?time_ms: Integer, ?velocity: Integer) -> untyped
      def apply(yaw_raw: nil, pitch_raw: nil, time_ms: 0, velocity: 0)
        @yaw.write_pos(yaw_raw, time_ms: time_ms, speed: velocity)     if yaw_raw
        @pitch.write_pos(pitch_raw, time_ms: time_ms, speed: velocity) if pitch_raw
      end

      # Switches torque on both servos.
      #: (bool on) -> untyped
      def enable_torque(on)
        @yaw.enable_torque(on)
        @pitch.enable_torque(on)
      end

      # Reads the current raw position of each servo.
      #: () -> Hash[Symbol, untyped]
      def read_actual
        { yaw: @yaw.read_pos, pitch: @pitch.read_pos }
      end

      # Returns each servo's last read error and status byte as [error, status].
      #: () -> Hash[Symbol, Array[untyped]]
      def read_health
        { yaw: [@yaw.last_read_error, @yaw.last_status], pitch: [@pitch.last_read_error, @pitch.last_status] }
      end

      # Wiggles the yaw servo by 10 raw units each way and back to zero.
      #: () -> untyped
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
