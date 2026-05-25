module StackchanNotifier
  module NotifyMotionTable
    # Maps face symbol to a single servo head pose. Sent alongside face/LED
    # when stackchan-notify is invoked without --silent.
    #
    # yaw_left / yaw_right: 0..100 (normalized magnitudes; mutually exclusive)
    # pitch_up: 0..100 (normalized magnitude, upward tilt only)
    # time_ms: 0..2000 (interpolation duration; 0 = max speed)
    # Converted from old raw encoder units to normalized protocol values.
    MOTIONS = {
      neutral:   { yaw_left: nil, yaw_right: nil, pitch_up: 50, time_ms: 300 },
      smile:     { yaw_left: nil, yaw_right: nil, pitch_up: 60, time_ms: 300 },
      joy:       { yaw_left: nil, yaw_right: nil, pitch_up: 75, time_ms: 250 },
      surprised: { yaw_left: nil, yaw_right: nil, pitch_up: 100, time_ms: 120 },
      sad:       { yaw_left: nil, yaw_right: nil, pitch_up: 10, time_ms: 500 },
      angry:     { yaw_left: 15, yaw_right: nil, pitch_up: 50, time_ms: 200 },
    }.freeze

    module_function

    def lookup(face)
      MOTIONS[face]
    end
  end
end
