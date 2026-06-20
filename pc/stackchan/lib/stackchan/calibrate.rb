# frozen_string_literal: true

require_relative "ble"

module Stackchan
  module Calibrate
    EXIT_OK                     = 0
    EXIT_CALIBRATION_NEEDED     = 6
    EXIT_CALIBRATION_INCOMPLETE = 7

    POSE_PROMPTS = Stackchan::BLE::Calibration::POSE_PROMPTS

    # Drives the operator-paced calibration flow over a connected daemon.
    # The daemon owns the BLE link; this class owns prompts + stdout + the
    # decision tree that translates Calibration outcomes into exit codes.
    class Runner
      def initialize(daemon, stdin: $stdin, stdout: $stdout)
        @daemon = daemon
        @stdin = stdin
        @stdout = stdout
      end

      def run(align_only:, samples: 3, format: :ruby, engage_torque: false, no_torque_toggle: false)
        if align_only
          run_align_only(no_torque_toggle)
        else
          run_full_calibrate(samples, format, engage_torque, no_torque_toggle)
        end
      rescue Stackchan::BLE::Calibration::UnknownReadError => e
        warn "[FAIL] reason=#{e.message} domain=calibration (device returned unknown)"
        EXIT_CALIBRATION_NEEDED
      rescue Interrupt
        warn "[INTERRUPT] operator aborted calibration; torque remains off."
        EXIT_CALIBRATION_INCOMPLETE
      end

      private

      def prompt(msg)
        @stdout.print "#{msg} "
        @stdout.flush
        @stdin.gets
      end

      def run_align_only(skip_torque)
        unless skip_torque
          @stdout.puts "[1/3] sending <torque:off>..."
          @daemon.torque(false)
          @stdout.puts "       ACK ✓ (Face::Closed displayed)"
        end
        prompt("[2/3] Align FORWARD: head level, LCD facing operator. Press Enter when aligned (Ctrl-C to abort)...")
        unless skip_torque
          @stdout.puts "[3/3] sending <torque:on>..."
          @daemon.torque(true)
          @stdout.puts "       ACK ✓ (Face::Neutral displayed)"
        end
        @stdout.puts "[done] Ready for operation."
        EXIT_OK
      end

      def run_full_calibrate(samples, format, engage_torque, skip_torque)
        unless skip_torque
          @stdout.puts "[1/6] sending <torque:off>..."
          @daemon.torque(false)
          @stdout.puts "       ACK ✓"
        end

        poses = {}
        POSE_PROMPTS.each do |key, msg|
          prompt(msg)
          poses[key] = @daemon.sample_pose(samples: samples)
          @stdout.puts "       reading... yaw_raw=#{poses[key][:yaw_raw]} pitch_raw=#{poses[key][:pitch_raw]}"
        end

        anchors = Stackchan::BLE::Calibration.compute_anchors(
          forward:    poses[:forward],
          left_max:   poses[:left_max],
          right_max:  poses[:right_max],
          up_max:     poses[:up_max],
          fwd_verify: poses[:fwd_verify],
        )
        outcome = Stackchan::BLE::Calibration.classify_verify(**anchors[:forward_verify])

        if engage_torque && !skip_torque
          @daemon.torque(true)
          @stdout.puts "[engage] <torque:on> sent."
        end

        @stdout.puts "\n#{Stackchan::BLE::Calibration.format(anchors, format)}"
        case outcome
        when :pass then EXIT_OK
        when :warn
          warn "[WARN] verify Δ exceeded #{Stackchan::BLE::Calibration::PASS_TOLERANCE} (yaw=#{anchors[:forward_verify][:yaw_delta]}, pitch=#{anchors[:forward_verify][:pitch_delta]}). Constants printed; review before paste."
          EXIT_OK
        when :fail
          warn "[FAIL] verify Δ exceeded #{Stackchan::BLE::Calibration::FAIL_TOLERANCE}. Calibration incomplete."
          EXIT_CALIBRATION_INCOMPLETE
        end
      end
    end
  end
end
