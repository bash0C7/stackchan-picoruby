module StackChan
  class Robot
    module Face
      EYE_LEFT_CX  = 110
      EYE_LEFT_CY  = 100
      EYE_RIGHT_CX = 210
      EYE_RIGHT_CY = 100
      EYE_RX       = 4
      EYE_RY       = 4

      EYE_COLOR        = 0xFFFF
      MOUTH_COLOR      = 0xFFFF
      BACKGROUND_COLOR = 0x0000

      FACE_REGION_HEIGHT = 200

      MOUTH_CX         = 160
      MOUTH_CY         = 140
      MOUTH_HALF_WIDTH = 25

      SURPRISED_MOUTH_HALF_W = 6
      SURPRISED_MOUTH_HALF_H = 12

      BROW_OFFSET_Y    = 18
      BROW_HALF_LENGTH = 16
      BROW_INNER_DROP  = 8

      EYE_REGION_HALF_W = 6
      EYE_REGION_HALF_H = 6
      CLOSED_EYE_HALF_W = 4

      FEATURE_MARGIN = 2
      MOUTH_MAX_RISE = 18
      EYE_BAND_X   = EYE_LEFT_CX - BROW_HALF_LENGTH - FEATURE_MARGIN
      EYE_BAND_W   = (EYE_RIGHT_CX + BROW_HALF_LENGTH + FEATURE_MARGIN) - EYE_BAND_X
      EYE_BAND_Y   = EYE_LEFT_CY - BROW_OFFSET_Y - FEATURE_MARGIN
      EYE_BAND_H   = (EYE_LEFT_CY + EYE_RY + FEATURE_MARGIN) - EYE_BAND_Y
      MOUTH_BAND_X = MOUTH_CX - MOUTH_HALF_WIDTH - FEATURE_MARGIN
      MOUTH_BAND_W = (MOUTH_CX + MOUTH_HALF_WIDTH + FEATURE_MARGIN) - MOUTH_BAND_X
      MOUTH_BAND_Y = MOUTH_CY - MOUTH_MAX_RISE - FEATURE_MARGIN
      MOUTH_BAND_H = (MOUTH_CY + SURPRISED_MOUTH_HALF_H + FEATURE_MARGIN) - MOUTH_BAND_Y

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
          display.draw_rect(0, 0, 320, FACE_REGION_HEIGHT, BACKGROUND_COLOR, fill: true)
          draw_features(display)
        end

        def draw_features(display)
          draw_eyes(display)
          draw_mouth(display)
        end

        def redraw(display)
          display.draw_rect(EYE_BAND_X, EYE_BAND_Y, EYE_BAND_W, EYE_BAND_H,
                            BACKGROUND_COLOR, fill: true)
          display.draw_rect(MOUTH_BAND_X, MOUTH_BAND_Y, MOUTH_BAND_W, MOUTH_BAND_H,
                            BACKGROUND_COLOR, fill: true)
          draw_features(display)
        end

        def clear_eye_region(display)
          display.draw_rect(EYE_LEFT_CX  - EYE_REGION_HALF_W, EYE_LEFT_CY  - EYE_REGION_HALF_H,
                            EYE_REGION_HALF_W * 2, EYE_REGION_HALF_H * 2,
                            BACKGROUND_COLOR, fill: true)
          display.draw_rect(EYE_RIGHT_CX - EYE_REGION_HALF_W, EYE_RIGHT_CY - EYE_REGION_HALF_H,
                            EYE_REGION_HALF_W * 2, EYE_REGION_HALF_H * 2,
                            BACKGROUND_COLOR, fill: true)
        end

        def redraw_eyes_open(display)
          clear_eye_region(display)
          draw_eyes(display)
        end

        def redraw_eyes_closed(display)
          clear_eye_region(display)
          draw_closed_eyes(display)
        end

        def draw_closed_eyes(display)
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
      end

      class Neutral < Base
      end

      class Smile < Base
        DELTA_Y = 8
      end

      class Joy < Base
        DELTA_Y = 18
      end

      class Sad < Base
        DELTA_Y = -8
      end

      class Angry < Base
        def draw_features(display)
          super
          display.draw_line(
            EYE_LEFT_CX - BROW_HALF_LENGTH, EYE_LEFT_CY - BROW_OFFSET_Y,
            EYE_LEFT_CX + BROW_HALF_LENGTH, EYE_LEFT_CY - BROW_OFFSET_Y + BROW_INNER_DROP,
            EYE_COLOR
          )
          display.draw_line(
            EYE_RIGHT_CX - BROW_HALF_LENGTH, EYE_RIGHT_CY - BROW_OFFSET_Y + BROW_INNER_DROP,
            EYE_RIGHT_CX + BROW_HALF_LENGTH, EYE_RIGHT_CY - BROW_OFFSET_Y,
            EYE_COLOR
          )
        end
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

      class Closed < Base
        def draw_eyes(display)
          draw_closed_eyes(display)
        end

        def draw_features(display)
          draw_eyes(display)
        end
      end
    end
  end
end
