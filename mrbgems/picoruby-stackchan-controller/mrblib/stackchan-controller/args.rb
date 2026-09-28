module StackChan
  class Controller
    class Args
      attr_reader :words, :text

      def initialize(words, flags: [])
        @words =
          if words.nil?
            []
          elsif words.is_a?(String)
            words.split(" ")
          else
            words.dup
          end
        @flags       = flags
        @positionals = []
        @opts        = {}
        @set         = []
        parse
        @text = words.is_a?(String) ? words : @positionals.join(" ")
      end

      def [](i)
        @positionals[i]
      end

      def size
        @positionals.size
      end

      def opt(key)
        @opts[key]
      end

      def int(key)
        v = opt(key)
        v && v.to_i
      end

      def float(key)
        v = opt(key)
        v && v.to_f
      end

      def flag?(key)
        raise ArgumentError, "flag?: --#{key} is not a declared flag" unless @flags.include?(key)
        @set.include?(key)
      end

      private

      def parse
        i = 0
        while i < @words.size
          w = @words[i]
          if w.is_a?(String) && w.length > 2 && w[0, 2] == "--"
            body = w[2, w.length - 2]
            if body.include?("=")
              k, v = body.split("=", 2)
              @opts[k] = v
              i += 1
            elsif @flags.include?(body)
              @set << body
              i += 1
            else
              @opts[body] = @words[i + 1]
              i += 2
            end
          else
            @positionals << w
            i += 1
          end
        end
      end
    end
  end
end
