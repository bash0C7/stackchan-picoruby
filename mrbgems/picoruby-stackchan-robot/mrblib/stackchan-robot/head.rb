module StackChan
  class Robot
    # The yaw and pitch servo pair. Takes raw servo positions and reads them back.
    class Head
      YAW_RANGE_RAW   = 300
      PITCH_RANGE_RAW = 296

      SERVO_YAW_ZERO   = 482
      SERVO_PITCH_ZERO = 633

      # @rbs!
      #   interface _Servo
      #     def write_pos: (Integer pos, time_ms: Integer, speed: Integer) -> bool
      #     def read_pos: () -> Integer?
      #     def enable_torque: (bool on) -> bool
      #     def last_read_error: () -> Symbol?
      #     def last_status: () -> Integer?
      #   end
      # @rbs @yaw: _Servo
      # @rbs @pitch: _Servo

      # Stores the yaw and pitch servos.
      #: (_Servo yaw_servo, _Servo pitch_servo) -> void
      def initialize(yaw_servo, pitch_servo)
        @yaw   = yaw_servo
        @pitch = pitch_servo
      end

      # Writes the given raw positions (nil skips that axis) with time_ms and velocity.
      #: (?yaw_raw: Integer?, ?pitch_raw: Integer?, ?time_ms: Integer, ?velocity: Integer) -> bool?
      def apply(yaw_raw: nil, pitch_raw: nil, time_ms: 0, velocity: 0)
        @yaw.write_pos(yaw_raw, time_ms: time_ms, speed: velocity)     if yaw_raw
        @pitch.write_pos(pitch_raw, time_ms: time_ms, speed: velocity) if pitch_raw
      end

      # Switches torque on both servos.
      #: (bool on) -> bool
      def enable_torque(on)
        @yaw.enable_torque(on)
        @pitch.enable_torque(on)
      end

      # Reads the current raw position of each servo.
      #: () -> { yaw: Integer?, pitch: Integer? }
      def read_actual
        { yaw: @yaw.read_pos, pitch: @pitch.read_pos }
      end

      # Returns each servo's last read error and status byte as [error, status].
      #: () -> { yaw: [Symbol?, Integer?], pitch: [Symbol?, Integer?] }
      def read_health
        { yaw: [@yaw.last_read_error, @yaw.last_status], pitch: [@pitch.last_read_error, @pitch.last_status] }
      end

      # Wiggles the yaw servo by 10 raw units each way and back to zero.
      #: () -> Array[Integer]
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
