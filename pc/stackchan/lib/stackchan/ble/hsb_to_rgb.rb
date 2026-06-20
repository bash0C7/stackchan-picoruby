module Stackchan::BLE
  module HsbToRgb
    module_function

    # Convert a 24-bit packed HSB value (0xHHSSBB) to [r, g, b] each in 0..255.
    #
    #   HH = hue          0..255 mapped linearly to 0..360 degrees
    #   SS = saturation   0..255 mapped linearly to 0..1
    #   BB = brightness   0..255 mapped linearly to 0..1
    #
    # Uses the standard HSV → RGB algorithm (six 60° hexagon sectors).
    def convert(packed)
      h_byte = (packed >> 16) & 0xFF
      s_byte = (packed >> 8) & 0xFF
      b_byte = packed & 0xFF

      v = b_byte / 255.0
      s = s_byte / 255.0
      h = (h_byte / 255.0) * 360.0

      c = v * s
      h_prime = h / 60.0
      x = c * (1 - ((h_prime % 2) - 1).abs)

      r1, g1, b1 =
        case h_prime.to_i
        when 0 then [c, x, 0]
        when 1 then [x, c, 0]
        when 2 then [0, c, x]
        when 3 then [0, x, c]
        when 4 then [x, 0, c]
        else        [c, 0, x]
        end

      m = v - c
      [(r1 + m) * 255, (g1 + m) * 255, (b1 + m) * 255].map { |f| f.round.clamp(0, 255) }
    end
  end
end
