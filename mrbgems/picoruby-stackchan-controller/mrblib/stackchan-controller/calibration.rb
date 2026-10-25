require "json"

module StackChan
  class Controller
    # Pure functions that turn recorded servo poses into calibration anchors and format them.
    module Calibration
      # @rbs!
      #   type pose = { yaw_raw: Integer, pitch_raw: Integer }
      #   type poses = { forward: pose, left_max: pose, right_max: pose, up_max: pose, fwd_verify: pose }
      #   type forward_verify = { yaw_delta: Integer, pitch_delta: Integer }
      #   type anchors = { servo_yaw_zero: Integer, servo_pitch_zero: Integer, yaw_range_raw: Integer, pitch_range_raw: Integer, forward_verify: forward_verify }

      PASS_TOLERANCE = 3
      FAIL_TOLERANCE = 10
      FORMATS = %i[ruby env json]
      UNKNOWN_POSITION = "device returned unknown raw position"

      POSE_PROMPTS = [
        [:forward,    "[2/6] Align FORWARD: head level, LCD facing operator. Press Enter..."],
        [:left_max,   "[3/6] LEFT MAX (90 deg): LCD faces operator's RIGHT. Press Enter..."],
        [:right_max,  "[4/6] RIGHT MAX (90 deg): LCD faces operator's LEFT. Press Enter..."],
        [:up_max,     "[5/6] UP MAX (90 deg): LCD faces ceiling. Press Enter..."],
        [:fwd_verify, "[6/6] Re-align FORWARD for verification. Press Enter..."],
      ]

      # Returns the lower median of the values.
      # Raises ArgumentError when values is empty.
      #: (Array[Integer] values) -> Integer
      def median(values)
        raise ArgumentError, "median requires at least 1 value" if values.empty?
        sorted = values.sort
        sorted[(sorted.length - 1) / 2]
      end

      # Returns the servo zero positions, the smaller of the left and right yaw radii, the pitch range and the forward re-check deltas from the five recorded poses.
      #: (poses poses) -> anchors
      def compute_anchors(poses)
        yaw_zero   = poses[:forward][:yaw_raw]
        pitch_zero = poses[:forward][:pitch_raw]
        left_radius  = (poses[:left_max][:yaw_raw]  - yaw_zero).abs
        right_radius = (poses[:right_max][:yaw_raw] - yaw_zero).abs
        {
          servo_yaw_zero:   yaw_zero,
          servo_pitch_zero: pitch_zero,
          yaw_range_raw:    (left_radius < right_radius ? left_radius : right_radius),
          pitch_range_raw:  (poses[:up_max][:pitch_raw] - pitch_zero).abs,
          forward_verify: {
            yaw_delta:   poses[:fwd_verify][:yaw_raw]   - yaw_zero,
            pitch_delta: poses[:fwd_verify][:pitch_raw] - pitch_zero,
          },
        }
      end

      # Returns :fail when the larger forward delta exceeds FAIL_TOLERANCE, :warn when it exceeds PASS_TOLERANCE, otherwise :pass.
      #: (forward_verify forward_verify) -> (:pass | :warn | :fail)
      def classify_verify(forward_verify)
        yd = forward_verify[:yaw_delta].abs
        pd = forward_verify[:pitch_delta].abs
        worst = yd > pd ? yd : pd
        return :fail if worst > FAIL_TOLERANCE
        return :warn if worst > PASS_TOLERANCE
        :pass
      end

      # Renders the anchors as Ruby constants, env lines or JSON; fmt is :ruby, :env, :json or the same as a String.
      # Raises ArgumentError for any other fmt.
      #: (anchors anchors, Symbol | String fmt) -> String
      def format(anchors, fmt)
        case fmt
        when :ruby, "ruby"
          "SERVO_YAW_ZERO   = #{anchors[:servo_yaw_zero]}\n" \
          "SERVO_PITCH_ZERO = #{anchors[:servo_pitch_zero]}\n" \
          "YAW_RANGE_RAW    = #{anchors[:yaw_range_raw]}\n" \
          "PITCH_RANGE_RAW  = #{anchors[:pitch_range_raw]}\n"
        when :env, "env"
          "SERVO_YAW_ZERO=#{anchors[:servo_yaw_zero]}\n" \
          "SERVO_PITCH_ZERO=#{anchors[:servo_pitch_zero]}\n" \
          "YAW_RANGE_RAW=#{anchors[:yaw_range_raw]}\n" \
          "PITCH_RANGE_RAW=#{anchors[:pitch_range_raw]}\n"
        when :json, "json"
          JSON.generate({
            servo_yaw_zero:   anchors[:servo_yaw_zero],
            servo_pitch_zero: anchors[:servo_pitch_zero],
            yaw_range_raw:    anchors[:yaw_range_raw],
            pitch_range_raw:  anchors[:pitch_range_raw],
            forward_verify:   anchors[:forward_verify],
          })
        else
          raise ArgumentError, "unknown format: #{fmt.inspect}"
        end
      end

      # Parses a "<yaw_raw:N,pitch_raw:M>" detail frame into {yaw_raw:, pitch_raw:}; a missing or "unknown" value is nil.
      #: (String? frame) -> { yaw_raw: Integer?, pitch_raw: Integer? }
      def parse_raw_detail(frame)
        s = frame.to_s
        s = s[0, s.length - 1] while s.length > 0 && (s[-1] == "\n" || s[-1] == "\r")
        s = s[1, s.length - 2] if s.length >= 2 && s[0] == "<" && s[-1] == ">"
        yaw = nil
        pitch = nil
        s.split(",").each do |pair|
          k, v = pair.split(":", 2)
          next unless v
          val = (v == "unknown" ? nil : v.to_i)
          yaw = val   if k == "yaw_raw"
          pitch = val if k == "pitch_raw"
        end
        { yaw_raw: yaw, pitch_raw: pitch }
      end

      module_function :median, :compute_anchors, :classify_verify, :format, :parse_raw_detail
    end
  end
end
