require "json"

module StackchanBleClient
  module Calibration
    module_function

    def median(values)
      raise ArgumentError, "median requires at least 1 value" if values.empty?
      sorted = values.sort
      sorted[(sorted.length - 1) / 2]
    end

    def compute_anchors(forward:, left_max:, right_max:, up_max:, fwd_verify:)
      yaw_zero   = forward[:yaw_raw]
      pitch_zero = forward[:pitch_raw]
      left_radius  = (left_max[:yaw_raw]  - yaw_zero).abs
      right_radius = (right_max[:yaw_raw] - yaw_zero).abs
      {
        servo_yaw_zero:   yaw_zero,
        servo_pitch_zero: pitch_zero,
        yaw_range_raw:    [left_radius, right_radius].min,
        pitch_range_raw:  (up_max[:pitch_raw] - pitch_zero).abs,
        forward_verify: {
          yaw_delta:   fwd_verify[:yaw_raw]   - yaw_zero,
          pitch_delta: fwd_verify[:pitch_raw] - pitch_zero,
        },
      }
    end

    PASS_TOLERANCE = 3
    FAIL_TOLERANCE = 10

    def classify_verify(yaw_delta:, pitch_delta:)
      worst = [yaw_delta.abs, pitch_delta.abs].max
      return :fail if worst > FAIL_TOLERANCE
      return :warn if worst > PASS_TOLERANCE
      :pass
    end

    def format(anchors, fmt)
      case fmt
      when :ruby then format_ruby(anchors)
      when :env  then format_env(anchors)
      when :json then format_json(anchors)
      else
        raise ArgumentError, "unknown format: #{fmt.inspect} (must be :ruby / :env / :json)"
      end
    end

    def format_ruby(a)
      <<~RUBY
        SERVO_YAW_ZERO   = #{a[:servo_yaw_zero]}
        SERVO_PITCH_ZERO = #{a[:servo_pitch_zero]}
        YAW_RANGE_RAW    = #{a[:yaw_range_raw]}
        PITCH_RANGE_RAW  = #{a[:pitch_range_raw]}
      RUBY
    end

    def format_env(a)
      "SERVO_YAW_ZERO=#{a[:servo_yaw_zero]}\n" \
      "SERVO_PITCH_ZERO=#{a[:servo_pitch_zero]}\n" \
      "YAW_RANGE_RAW=#{a[:yaw_range_raw]}\n" \
      "PITCH_RANGE_RAW=#{a[:pitch_range_raw]}\n"
    end

    def format_json(a)
      JSON.generate({
        servo_yaw_zero:   a[:servo_yaw_zero],
        servo_pitch_zero: a[:servo_pitch_zero],
        yaw_range_raw:    a[:yaw_range_raw],
        pitch_range_raw:  a[:pitch_range_raw],
        forward_verify:   a[:forward_verify],
      })
    end

    def parse_raw_detail(frame)
      m = frame.match(/\A<yaw_raw:(unknown|-?\d+),pitch_raw:(unknown|-?\d+)>\n?\z/)
      raise ArgumentError, "not a raw detail frame: #{frame.inspect}" unless m
      {
        yaw_raw:   (m[1] == "unknown" ? nil : m[1].to_i),
        pitch_raw: (m[2] == "unknown" ? nil : m[2].to_i),
      }
    end

    class UnknownReadError < StandardError; end

    def sample_pose(client, samples:)
      readings = []
      samples.times do
        client.send { |s| s.read_pos }
        parsed = parse_raw_detail(client.last_detail_frame.to_s)
        raise UnknownReadError, "device returned unknown" if parsed[:yaw_raw].nil? || parsed[:pitch_raw].nil?
        readings << parsed
      end
      {
        yaw_raw:   median(readings.map { |r| r[:yaw_raw] }),
        pitch_raw: median(readings.map { |r| r[:pitch_raw] }),
      }
    end
  end
end
