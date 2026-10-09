module DRbBle
  CHUNK = 180

  class Incomplete < StandardError; end

  def self.chunks(data, size = CHUNK)
    out = []
    pos = 0
    while pos < data.bytesize
      out << data.byteslice(pos, size)
      pos += size
    end
    out
  end

  class Reader
    attr_reader :pos

    def initialize(buf)
      @buf = buf
      @pos = 0
    end

    def read(n)
      raise Incomplete if @pos + n > @buf.bytesize
      @pos += n
      @buf.byteslice(@pos - n, n)
    end
  end

  class Writer
    attr_reader :out

    def initialize
      @out = ""
    end

    def write(s)
      @out << s
    end
  end

  class Responder
    MAX_REQUEST = 4096

    def initialize(front, allow:)
      @front = front
      @allow = allow
      reset
    end

    def reset
      @buf = ""
      @fields = []
      @taken = 0
    end

    def feed(bytes)
      @buf << bytes
      out = ""
      while (data = take_message)
        begin
          @fields << Marshal.load(data)
        rescue
          reset
          break
        end
        unless well_formed?
          reset
          break
        end
        next unless @fields.size >= 4 && @fields.size == @fields[2] + 4
        out << reply(@fields[0], @fields[1].to_sym, @fields[3, @fields[2]])
        @fields = []
        @taken = 0
      end
      reset if @taken + @buf.bytesize > MAX_REQUEST
      out
    end

    private

    def take_message
      return nil if @buf.bytesize < 4
      size = @buf.byteslice(0, 4).unpack("N")[0]
      return nil if @buf.bytesize < 4 + size
      data = @buf.byteslice(4, size)
      @buf = @buf.byteslice(4 + size, @buf.bytesize - 4 - size)
      @taken += 4 + size
      data
    end

    def well_formed?
      return @fields[1].is_a?(String) if @fields.size == 2
      return @fields[2].is_a?(Integer) && @fields[2] >= 0 if @fields.size == 3
      true
    end

    def reply(ref, msg, args)
      w = Writer.new
      m = DRb::DRbMessage.new(w)
      if ref.nil? && @allow.include?(msg)
        begin
          m.send_reply(true, @front.send(msg, *args))
        rescue => e
          m.send_reply(false, "#{e.class}: #{e.message}")
        end
      else
        m.send_reply(false, "NoMethodError: #{msg} is not exposed")
      end
      w.out
    end
  end

  class Socket
    POLL_MS = 20

    def initialize(link, timeout_ms)
      @link = link
      @timeout_ms = timeout_ms
      @tx = ""
      @rx = ""
    end

    def write(s)
      @tx << s
    end

    def read(n)
      DRbBle.chunks(@tx).each { |c| @link.send_chunk(c) }
      @tx = ""
      waited = 0
      while @rx.bytesize < n
        data = @link.poll
        if data
          @rx << data
        elsif waited >= @timeout_ms
          raise DRb::DRbConnError, "drbble: no reply in #{@timeout_ms} ms"
        else
          sleep_ms POLL_MS
          waited += POLL_MS
        end
      end
      s = @rx.byteslice(0, n)
      @rx = @rx.byteslice(n, @rx.bytesize - n)
      s
    end

    def close
    end
  end

  @links = {}

  def self.register(uri, link, timeout_ms: 3000)
    @links[uri] = [link, timeout_ms]
  end

  def self.socket(uri)
    link, timeout_ms = @links[uri]
    raise DRb::DRbBadURI, "drbble: no link registered for #{uri}" unless link
    Socket.new(link, timeout_ms)
  end
end

module DRb
  class << self
    alias_method :_ble_base_create_socket, :create_socket

    def create_socket(uri)
      uri.to_s.start_with?("drbble://") ? DRbBle.socket(uri.to_s) : _ble_base_create_socket(uri)
    end
  end
end
