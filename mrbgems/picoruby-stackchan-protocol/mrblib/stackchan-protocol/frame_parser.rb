module StackchanProtocol
  # Splits a byte stream into "<key:value,...>" frames and decodes each into a Hash.
  # Keeps the last MAX_BUFFER characters of unparsed input.
  class FrameParser
    # @rbs @buffer: String

    MAX_BUFFER = 4096

    # Creates a parser with an empty buffer.
    #: () -> void
    def initialize
      @buffer = String.new
    end

    # Appends chunk and returns the Hash of every complete frame now available, in order.
    # Frames with no key:value pair are dropped.
    #: (String chunk) -> Array[Hash[String, String]]
    def feed(chunk)
      @buffer << chunk
      if @buffer.size > MAX_BUFFER
        @buffer = @buffer[(@buffer.size - MAX_BUFFER), MAX_BUFFER]
      end
      frames = []
      while (s = @buffer.index('<'))
        e = @buffer.index('>', s)
        break unless e
        raw = @buffer[s, e - s + 1]
        @buffer = @buffer[(e + 1), @buffer.size - (e + 1)]
        decoded = decode(raw)
        frames << decoded if decoded
      end
      frames
    end

    # Discards the buffered input.
    #: () -> void
    def reset
      @buffer = String.new
    end

    private

    # Decodes one "<k:v,k:v>" frame into a Hash, or returns nil when it holds no pair.
    #: (String raw) -> Hash[String, String]?
    def decode(raw)
      return nil if raw.size < 3
      body = raw[1, raw.size - 2]
      h = {}
      body.split(',').each do |pair|
        kv = pair.split(':', 2)
        next unless kv.size == 2
        h[kv[0]] = kv[1]
      end
      h.empty? ? nil : h
    end
  end
end
