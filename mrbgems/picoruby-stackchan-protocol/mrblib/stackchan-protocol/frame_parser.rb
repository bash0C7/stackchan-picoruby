module StackchanProtocol
  class FrameParser
    MAX_BUFFER = 4096

    def initialize
      @buffer = String.new
    end

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

    private

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
