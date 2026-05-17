require_relative "face_table"
require_relative "led_color_table"
require_relative "frame_codec"
require_relative "hsb_to_rgb"

module StackchanBleClient
  class SendBuilder
    def initialize
      @commands = {}   # key → command hash
      @order    = []   # first-occurrence ordering of keys
    end

    def face(name)
      record(:face, { kind: :face, name: name })
    end

    def led(form, value = nil, side: :both, mode: :solid)
      record([:led, side], { kind: :led, form: form, value: value, side: side, mode: mode })
    end

    def to_frames
      @order.map { |key| encode(@commands.fetch(key)) }
    end

    private

    def record(key, params)
      @order << key unless @commands.key?(key)
      @commands[key] = params
    end

    def encode(cmd)
      case cmd[:kind]
      when :face
        FrameCodec.encode_face(face_name: cmd[:name])
      when :led
        r, g, b = resolve_color(cmd[:form], cmd[:value])
        FrameCodec.encode_led(r: r, g: g, b: b, side: cmd[:side], mode: cmd[:mode])
      end
    end

    def resolve_color(form, value)
      case form
      when :rgb
        [(value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF]
      when :hsb
        HsbToRgb.convert(value)
      when Symbol
        LedColorTable::LED_COLORS.fetch(form) do
          raise ArgumentError, "unknown LED form / named color: #{form.inspect}"
        end
      else
        raise ArgumentError, "LED form must be a Symbol, got #{form.inspect}"
      end
    end
  end
end
