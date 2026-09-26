# dRuby over BLE: DRb's TCP byte stream, cut into ATT-sized chunks.
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

  # socket#read over a String; Incomplete until the bytes are there.
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

  # Peripheral side: feed each BLE write, get back the reply bytes ("" if none).
  # A request that does not parse, or outgrows MAX_REQUEST, is dropped.
  class Responder
    MAX_REQUEST = 4096

    def initialize(front, allow:)
      @front = front
      @allow = allow
      @buf = ""
    end

    def reset
      @buf = ""
    end

    def feed(bytes)
      @buf << bytes
      out = ""
      while true
        reader = Reader.new(@buf)
        begin
          ref, msg, args = DRb::DRbMessage.new(reader).recv_request
        rescue Incomplete
          reset if @buf.bytesize > MAX_REQUEST
          break
        rescue
          reset
          break
        end
        @buf = @buf.byteslice(reader.pos, @buf.bytesize - reader.pos)
        out << reply(ref, msg, args)
      end
      out
    end

    private

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

  # Central side: the socket DRb.send_message uses. Writes go out on the first
  # read. link: send_chunk(bytes) / poll -> String or nil.
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
