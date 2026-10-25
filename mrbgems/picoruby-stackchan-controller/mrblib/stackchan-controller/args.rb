module StackChan
  class Controller
    # Parsed words of one action call: positionals, --key value options and declared --flags.
    class Args
      # @rbs @words: Array[String]
      # @rbs @flags: Array[String]
      # @rbs @positionals: Array[String]
      # @rbs @opts: Hash[String, String?]
      # @rbs @set: Array[String]

      attr_reader :words #: Array[String]
      attr_reader :text #: String

      # Splits words (a String on spaces, an Array, or nil) into positionals, options and the declared flags; text is the original String or the joined positionals.
      #: (String | Array[String] | nil words, ?flags: Array[String]) -> void
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

      # Returns the i-th positional word, or nil.
      #: (Integer i) -> String?
      def [](i)
        @positionals[i]
      end

      # Returns the number of positional words.
      #: () -> Integer
      def size
        @positionals.size
      end

      # Returns the raw String value of --key, or nil.
      #: (String key) -> String?
      def opt(key)
        @opts[key]
      end

      # Returns the value of --key as an Integer, or nil.
      #: (String key) -> Integer?
      def int(key)
        v = opt(key)
        v && v.to_i
      end

      # Returns the value of --key as a Float, or nil.
      #: (String key) -> Float?
      def float(key)
        v = opt(key)
        v && v.to_f
      end

      # Returns whether the declared flag --key was given.
      # Raises ArgumentError when key is not a declared flag.
      #: (String key) -> bool
      def flag?(key)
        raise ArgumentError, "flag?: --#{key} is not a declared flag" unless @flags.include?(key)
        @set.include?(key)
      end

      private

      # Fills the positionals, options and set flags from the words.
      #: () -> void
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
