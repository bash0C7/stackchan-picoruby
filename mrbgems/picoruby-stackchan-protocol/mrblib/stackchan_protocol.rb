module StackchanProtocol
  module Face
    # Geometry derived from the M5Stack official StackChan reference photo.
    # Ratios (normalised to screen 320×240):
    #   eye-to-eye   : 0.31 W  = 100 px  (offset ±50 from cx=160)
    #   eye_y        : 0.42 H  = 100 px  (slightly above geometric centre y=120)
    #   mouth_y      : 0.58 H  = 140 px  (slightly below centre, gap 40 from eye)
    #   eye diameter : 0.025 W = 8  px   (radius 4)
    #   mouth width  : 0.16 W  = 50 px   (half-width 25)
    EYE_LEFT_CX  = 110
    EYE_LEFT_CY  = 100
    EYE_RIGHT_CX = 210
    EYE_RIGHT_CY = 100
    EYE_RX       = 4
    EYE_RY       = 4

    EYE_COLOR        = ILI9342::Color::WHITE
    MOUTH_COLOR      = ILI9342::Color::WHITE
    BACKGROUND_COLOR = ILI9342::Color::BLACK

    MOUTH_CX         = 160
    MOUTH_CY         = 140
    MOUTH_HALF_WIDTH = 25

    # Surprised mouth — vertical filled rectangle (open mouth).
    SURPRISED_MOUTH_HALF_W = 6
    SURPRISED_MOUTH_HALF_H = 12

    class Base
      DELTA_Y = 0

      def draw_eyes(display)
        display.draw_ellipse(EYE_LEFT_CX,  EYE_LEFT_CY,  EYE_RX, EYE_RY, EYE_COLOR, fill: true)
        display.draw_ellipse(EYE_RIGHT_CX, EYE_RIGHT_CY, EYE_RX, EYE_RY, EYE_COLOR, fill: true)
      end

      def draw_mouth(display)
        cx = MOUTH_CX
        cy = MOUTH_CY
        hw = MOUTH_HALF_WIDTH
        left_x   = cx - hw
        right_x  = cx + hw
        corner_y = cy - self.class::DELTA_Y
        display.draw_line(left_x, corner_y, cx,      cy,       MOUTH_COLOR)
        display.draw_line(cx,     cy,       right_x, corner_y, MOUTH_COLOR)
      end

      def draw(display)
        display.fill(BACKGROUND_COLOR)
        draw_eyes(display)
        draw_mouth(display)
      end

      # Clear the small bounding box around each eye to BACKGROUND_COLOR,
      # without touching the mouth or wider background. Used to wipe the
      # previous eye shape (open ellipse or closed line) before redrawing.
      def clear_eye_region(display)
        display.draw_rect(EYE_LEFT_CX  - EYE_REGION_HALF_W, EYE_LEFT_CY  - EYE_REGION_HALF_H,
                          EYE_REGION_HALF_W * 2, EYE_REGION_HALF_H * 2,
                          BACKGROUND_COLOR, fill: true)
        display.draw_rect(EYE_RIGHT_CX - EYE_REGION_HALF_W, EYE_RIGHT_CY - EYE_REGION_HALF_H,
                          EYE_REGION_HALF_W * 2, EYE_REGION_HALF_H * 2,
                          BACKGROUND_COLOR, fill: true)
      end

      # Update only the eye region (clear + redraw eyes), keeping the mouth
      # and overall background untouched. Used for blink restore.
      def redraw_eyes_open(display)
        clear_eye_region(display)
        draw_eyes(display)
      end
    end

    class Neutral < Base
      DELTA_Y = 0
    end

    class Smile < Base
      DELTA_Y = 8
    end

    class Joy < Base
      DELTA_Y = 18
    end

    class Surprised < Base
      def draw_mouth(display)
        display.draw_rect(
          MOUTH_CX - SURPRISED_MOUTH_HALF_W,
          MOUTH_CY - SURPRISED_MOUTH_HALF_H,
          SURPRISED_MOUTH_HALF_W * 2,
          SURPRISED_MOUTH_HALF_H * 2,
          MOUTH_COLOR,
          fill: true
        )
      end
    end

    # Eye-region bounding box for eye-only updates (blink animation).
    # Large enough to cover both the open ellipse (EYE_RX/RY) and the closed
    # horizontal line (CLOSED_EYE_HALF_W), so clearing this region wipes
    # either shape cleanly.
    EYE_REGION_HALF_W = 6
    EYE_REGION_HALF_H = 6

    # Closed eye for blink animation. Draws a short horizontal line where
    # the eye normally sits, giving the impression of a closed lid.
    CLOSED_EYE_HALF_W = 4

    class Closed < Base
      def draw_eyes(display)
        display.draw_line(
          EYE_LEFT_CX - CLOSED_EYE_HALF_W, EYE_LEFT_CY,
          EYE_LEFT_CX + CLOSED_EYE_HALF_W, EYE_LEFT_CY,
          EYE_COLOR
        )
        display.draw_line(
          EYE_RIGHT_CX - CLOSED_EYE_HALF_W, EYE_RIGHT_CY,
          EYE_RIGHT_CX + CLOSED_EYE_HALF_W, EYE_RIGHT_CY,
          EYE_COLOR
        )
      end

      # Override Base#draw to do eye-only update: no full-screen fill, no mouth
      # redraw. This is used as the "blink close" frame so screen does not
      # flicker visibly.
      def draw(display)
        clear_eye_region(display)
        draw_eyes(display)
      end
    end
  end
end

