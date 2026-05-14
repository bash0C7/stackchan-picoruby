module StackchanProtocol
  class FrameParser
    MAX_BUFFER = 4096

    attr_reader :parse_error_count

    def initialize
      @buffer = String.new
      @parse_error_count = 0
    end

    def feed(chunk)
      @buffer << chunk
      if @buffer.bytesize > MAX_BUFFER
        @buffer = @buffer[(@buffer.bytesize - MAX_BUFFER), MAX_BUFFER]
      end
      frames = []
      while (s = @buffer.index('<'))
        e = @buffer.index('>', s)
        break unless e
        raw = @buffer[s, e - s + 1]
        @buffer = @buffer[(e + 1), @buffer.bytesize - (e + 1)] || ""
        decoded = decode(raw)
        if decoded
          frames << decoded
        else
          @parse_error_count += 1
        end
      end
      frames
    end

    private

    def decode(raw)
      return nil if raw.bytesize < 3
      body = raw[1, raw.bytesize - 2]
      return nil if body.nil? || body.empty?
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
