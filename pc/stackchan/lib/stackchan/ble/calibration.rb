require "json"

module Stackchan::BLE
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

    def run_align_only(client:, prompt:, stdout:, skip_torque: false)
      unless skip_torque
        stdout.puts "[1/3] sending <torque:off>..."
        client.send { |s| s.torque(on: false) }
        stdout.puts "       ACK ✓ (Face::Closed displayed)"
      end
      prompt.call("[2/3] Align FORWARD: head level, LCD facing operator. Press Enter when aligned (Ctrl-C to abort)...")
      unless skip_torque
        stdout.puts "[3/3] sending <torque:on>..."
        client.send { |s| s.torque(on: true) }
        stdout.puts "       ACK ✓ (Face::Neutral displayed)"
      end
      stdout.puts "[done] Ready for operation."
    end

    # Logical MAX = 90° from forward (the operational comfort range).
    # Yaw is physically continuous-rotation (no hard stop), so MAX is a
    # logical landmark the operator dials in by hand — LCD faces directly
    # perpendicular to forward. Pitch UP MAX = LCD faces straight ceiling.
    POSE_PROMPTS = [
      [:forward,    "[2/6] Align FORWARD: head level, LCD facing operator. Press Enter..."],
      [:left_max,   "[3/6] LEFT MAX (90°): rotate head so LCD faces operator's RIGHT side. Press Enter..."],
      [:right_max,  "[4/6] RIGHT MAX (90°): rotate head so LCD faces operator's LEFT side. Press Enter..."],
      [:up_max,     "[5/6] UP MAX (90°): tilt head so LCD faces ceiling. Press Enter..."],
      [:fwd_verify, "[6/6] Re-align FORWARD for verification (LCD facing operator). Press Enter..."],
    ].freeze

    def run_full_calibrate(client:, prompt:, stdout:, samples:, engage_torque:, skip_torque: false)
      unless skip_torque
        stdout.puts "[1/6] sending <torque:off>..."
        client.send { |s| s.torque(on: false) }
        stdout.puts "       ACK ✓"
      end

      poses = {}
      POSE_PROMPTS.each do |key, msg|
        prompt.call(msg)
        poses[key] = sample_pose(client, samples: samples)
        stdout.puts "       reading... yaw_raw=#{poses[key][:yaw_raw]} pitch_raw=#{poses[key][:pitch_raw]}"
      end

      anchors = compute_anchors(
        forward:    poses[:forward],
        left_max:   poses[:left_max],
        right_max:  poses[:right_max],
        up_max:     poses[:up_max],
        fwd_verify: poses[:fwd_verify],
      )
      outcome = classify_verify(**anchors[:forward_verify])

      if engage_torque && !skip_torque
        client.send { |s| s.torque(on: true) }
        stdout.puts "[engage] <torque:on> sent."
      end

      { outcome: outcome, anchors: anchors, poses: poses }
    end
  end
end
