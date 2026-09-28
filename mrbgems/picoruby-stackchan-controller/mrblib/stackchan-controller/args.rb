module StackChan
  class Controller
    class Args
      attr_reader :words

      def initialize(words)
        @words =
          if words.nil?
            []
          elsif words.is_a?(String)
            words.split(" ")
          else
            words.dup
          end
        @flags = []
      end

      def [](i)
        positionals[i]
      end

      def size
        positionals.size
      end

      def opt(key)
        return nil if @flags.include?(key)
        i = @words.index("--#{key}")
        return nil unless i
        value = @words[i + 1]
        return nil if value.nil? || option?(value)
        value
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
        @flags << key unless @flags.include?(key)
        @words.include?("--#{key}")
      end

      private

      def option?(word)
        word.is_a?(String) && word.length > 2 && word[0, 2] == "--"
      end

      def positionals
        out = []
        i = 0
        while i < @words.size
          w = @words[i]
          if option?(w)
            nxt = @words[i + 1]
            i += (@flags.include?(w[2, w.length - 2]) || nxt.nil? || option?(nxt)) ? 1 : 2
          else
            out << w
            i += 1
          end
        end
        out
      end
    end
  end
end
