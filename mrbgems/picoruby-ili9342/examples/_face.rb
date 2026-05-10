# examples/_face.rb — shared face rendering helpers used by face_*.rb.
# Eye geometry stays constant across expressions; only the mouth's curve_delta changes.
#
# Geometry derived from m5stack/StackChan upstream
# (firmware/main/stackchan/avatar/skins/default/eyes.cpp + mouth.cpp), adapted
# for 320×240 landscape (screen center = (160, 120)).
#
# Upstream uses LVGL containers anchored at LV_ALIGN_CENTER with offsets:
#   eyes.cpp:13   _eye_pos = Vector2i(-70, -16)   ; mirrored for right eye
#   eyes.cpp:12   _eye_size = 16                  ; nominal eye size constant
#   eyes.cpp:16   _eye_size_limit = Vector2i(8,32); dynamic eye container 32×32
#   mouth.cpp:12  _mouth_pos = Vector2i(0, 26)
#   mouth.cpp:15  _mouth_min_size = Vector2i(90,6); neutral (weight=0) mouth
#
# Simplifications vs upstream:
#   - Static geometry only (no LVGL animation, no eyelid, no rotation).
#   - Eye drawn as a single filled ellipse using upstream's _eye_size=16 as the
#     radius (the upstream LVGL eye is dynamically sized 8..32 px diameter).
#   - Mouth rendered as two straight line segments forming an inverted-V (∧)
#     instead of a rounded LVGL container; delta_y controls smile lift.

module Face
  EYE_LEFT_CX  = 90    # 160 + (-70)
  EYE_LEFT_CY  = 104   # 120 + (-16)
  EYE_RIGHT_CX = 230   # 160 - (-70)  (upstream mirrors x for right eye)
  EYE_RIGHT_CY = 104
  EYE_RX       = 16    # upstream _eye_size constant
  EYE_RY       = 16

  MOUTH_CX           = 160  # 160 + 0
  MOUTH_CY           = 146  # 120 + 26
  MOUTH_HALF_WIDTH   = 45   # _mouth_min_size.x / 2 = 90 / 2

  EYE_COLOR        = ILI9342::Color::WHITE
  MOUTH_COLOR      = ILI9342::Color::WHITE
  BACKGROUND_COLOR = ILI9342::Color::BLACK

  def self.draw(display, mouth_delta_y)
    display.fill(BACKGROUND_COLOR)
    draw_eyes(display)
    draw_mouth(display, mouth_delta_y)
  end

  def self.draw_eyes(display)
    display.draw_ellipse(EYE_LEFT_CX,  EYE_LEFT_CY,  EYE_RX, EYE_RY, EYE_COLOR, fill: true)
    display.draw_ellipse(EYE_RIGHT_CX, EYE_RIGHT_CY, EYE_RX, EYE_RY, EYE_COLOR, fill: true)
  end

  # `delta_y` lifts the corners above the center: 0 = straight (neutral),
  # small positive = mild smile, larger positive = joy. Renders as two
  # straight segments forming an inverted-V (∧) — simple but readable.
  def self.draw_mouth(display, delta_y)
    cx = MOUTH_CX
    cy = MOUTH_CY
    hw = MOUTH_HALF_WIDTH
    left_x   = cx - hw
    right_x  = cx + hw
    corner_y = cy - delta_y
    display.draw_line(left_x,  corner_y, cx,      cy,       MOUTH_COLOR)
    display.draw_line(cx,      cy,       right_x, corner_y, MOUTH_COLOR)
  end
end
