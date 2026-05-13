module StackchanProtocol
  module Face
    EYE_LEFT_CX  = 90
    EYE_LEFT_CY  = 104
    EYE_RIGHT_CX = 230
    EYE_RIGHT_CY = 104
    EYE_RX       = 16
    EYE_RY       = 16

    EYE_COLOR        = ILI9342::Color::WHITE
    MOUTH_COLOR      = ILI9342::Color::WHITE
    BACKGROUND_COLOR = ILI9342::Color::BLACK

    MOUTH_CX         = 160
    MOUTH_CY         = 146
    MOUTH_HALF_WIDTH = 45

    class Base
      def draw_eyes(display)
        display.draw_ellipse(EYE_LEFT_CX,  EYE_LEFT_CY,  EYE_RX, EYE_RY, EYE_COLOR, fill: true)
        display.draw_ellipse(EYE_RIGHT_CX, EYE_RIGHT_CY, EYE_RX, EYE_RY, EYE_COLOR, fill: true)
      end
    end
  end
end
