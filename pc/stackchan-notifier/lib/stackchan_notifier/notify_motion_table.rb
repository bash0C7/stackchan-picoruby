module StackchanNotifier
  module NotifyMotionTable
    # Maps face symbol to a single servo head pose. Sent alongside face/LED
    # when stackchan-notify is invoked without --silent.
    #
    # yaw: -1000..1000 (negative = StackChan's right, positive = its left)
    # pitch: 100..800 (100 = head down, 800 = head up, 450 = level)
    # time_ms: 0..2000 (interpolation duration; 0 = max speed)
    MOTIONS = {
      neutral:   { yaw:    0, pitch: 450, time_ms: 300 },
      smile:     { yaw:    0, pitch: 500, time_ms: 300 },
      joy:       { yaw:    0, pitch: 600, time_ms: 250 },
      surprised: { yaw:    0, pitch: 750, time_ms: 120 },
      sad:       { yaw:    0, pitch: 280, time_ms: 500 },
      angry:     { yaw:  150, pitch: 450, time_ms: 200 },
    }.freeze

    module_function

    def lookup(face)
      MOTIONS[face]
    end
  end
end
