module Stackchan
  module BLE
    # Collects commands (one per key, last write wins, first-occurrence order)
    # and encodes them into frames.
    class SendBuilder
      def initialize
        @commands = {}
        @order    = []
      end

      def face(name)
        record(:face, { kind: :face, name: name })
      end

      def led(form, value = nil, side: :both, mode: :solid)
        record([:led, side], { kind: :led, form: form, value: value, side: side, mode: mode })
      end

      def head(yaw_left: nil, yaw_right: nil, pitch_up: nil, time_ms: nil, velocity: nil)
        record(:head, {
          kind: :head,
          yaw_left: yaw_left, yaw_right: yaw_right, pitch_up: pitch_up,
          time_ms: time_ms, velocity: velocity,
        })
      end

      def torque(on:)
        record(:torque, { kind: :torque, on: on })
      end

      def selftest
        record(:selftest, { kind: :selftest })
      end

      def read_pos
        record(:read_pos, { kind: :read_pos })
      end

      def to_frames
        frames = []
        i = 0
        while i < @order.length
          frames << encode(@commands.fetch(@order[i]))
          i += 1
        end
        frames
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
        when :head
          FrameCodec.encode_head(
            yaw_left: cmd[:yaw_left], yaw_right: cmd[:yaw_right], pitch_up: cmd[:pitch_up],
            time_ms: cmd[:time_ms], velocity: cmd[:velocity],
          )
        when :torque
          FrameCodec.encode_torque(on: cmd[:on])
        when :selftest
          FrameCodec.encode_selftest
        when :read_pos
          FrameCodec.encode_read_pos
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
end
