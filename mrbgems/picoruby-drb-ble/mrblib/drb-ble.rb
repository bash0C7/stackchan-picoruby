# dRuby transport over BLE: a socket backed by a chunked link and a responder that serves a front object.
# DRb uses it for URIs that start with "drbble://".
module DRbBle
  # @rbs!
  #   interface _Link
  #     def send_chunk: (String bytes) -> void
  #     def poll: () -> String?
  #   end
  #
  #   interface _Stream
  #     def write: (String data) -> void
  #     def read: (Integer n) -> String?
  #     def close: () -> void
  #   end

  CHUNK = 180

  # Raised by Reader#read when the buffer holds fewer bytes than requested.
  class Incomplete < StandardError; end

  # Splits data into byte slices of at most size bytes.
  #: (String data, ?Integer size) -> Array[String]
  def self.chunks(data, size = CHUNK)
    out = []
    pos = 0
    while pos < data.bytesize
      out << data.byteslice(pos, size)
      pos += size
    end
    out
  end

  # Reads bytes sequentially from a String buffer.
  class Reader
    # @rbs @buf: String
    # @rbs @pos: Integer

    attr_reader :pos #: Integer

    # Creates a reader at the start of buf.
    #: (String buf) -> void
    def initialize(buf)
      @buf = buf
      @pos = 0
    end

    # Returns the next n bytes and advances; raises Incomplete when fewer than n remain.
    #: (Integer n) -> String
    def read(n)
      raise Incomplete if @pos + n > @buf.bytesize
      @pos += n
      @buf.byteslice(@pos - n, n)
    end
  end

  # Collects written strings into one buffer.
  class Writer
    # @rbs @out: String

    attr_reader :out #: String

    # Creates a writer with an empty buffer.
    #: () -> void
    def initialize
      @out = ""
    end

    # Appends s to the buffer.
    #: (String s) -> String
    def write(s)
      @out << s
    end
  end

  # Serves dRuby requests from bytes fed in: assembles request messages and calls allowed methods on the front.
  # Requests larger than MAX_REQUEST and malformed requests are dropped.
  class Responder
    # @rbs @front: Object
    # @rbs @allow: Array[Symbol]
    # @rbs @buf: String
    # @rbs @fields: Array[untyped]
    # @rbs @taken: Integer

    MAX_REQUEST = 4096

    # Creates a responder for front that exposes only the method names in allow.
    #: (Object front, allow: Array[Symbol]) -> void
    def initialize(front, allow:)
      @front = front
      @allow = allow
      reset
    end

    # Discards the buffered bytes and the partly received request.
    #: () -> void
    def reset
      @buf = ""
      @fields = []
      @taken = 0
    end

    # Appends bytes and returns the concatenated replies of every request completed by them, or "" if none.
    # Resets and drops the request when a message does not load or is malformed.
    #: (String bytes) -> String
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

    # Removes and returns the next length-prefixed message from the buffer, or nil if it is not complete.
    #: () -> String?
    def take_message
      return nil if @buf.bytesize < 4
      size = @buf.byteslice(0, 4).unpack("N")[0]
      return nil if @buf.bytesize < 4 + size
      data = @buf.byteslice(4, size)
      @buf = @buf.byteslice(4 + size, @buf.bytesize - 4 - size)
      @taken += 4 + size
      data
    end

    # Returns false when the fields received so far have the wrong types for a request header.
    #: () -> bool
    def well_formed?
      return @fields[1].is_a?(String) if @fields.size == 2
      return @fields[2].is_a?(Integer) && @fields[2] >= 0 if @fields.size == 3
      true
    end

    # Returns the serialized dRuby reply of calling msg on the front.
    # Replies with a failure for a method not in allow or when the call raises.
    #: (Object? ref, Symbol msg, Array[untyped] args) -> String
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

  # Socket-like object for DRb that sends written bytes over a link in chunks and reads the reply from it.
  class Socket
    # @rbs @link: _Link
    # @rbs @timeout_ms: Integer
    # @rbs @tx: String
    # @rbs @rx: String

    POLL_MS = 20

    # Creates a socket over link that gives up a read after timeout_ms without data.
    #: (_Link link, Integer timeout_ms) -> void
    def initialize(link, timeout_ms)
      @link = link
      @timeout_ms = timeout_ms
      @tx = ""
      @rx = ""
    end

    # Buffers s for the next read.
    #: (String s) -> String
    def write(s)
      @tx << s
    end

    # Sends the buffered bytes in chunks, then returns n bytes of the reply.
    # Raises DRb::DRbConnError when no data arrives within the timeout.
    #: (Integer n) -> String
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

    # Does nothing; the link stays open.
    #: () -> void
    def close
    end
  end

  @links = {}

  # Registers link and its read timeout for the URI.
  #: (String uri, _Link link, ?timeout_ms: Integer) -> [_Link, Integer]
  def self.register(uri, link, timeout_ms: 3000)
    @links[uri] = [link, timeout_ms]
  end

  # Returns a Socket for the link registered for uri; raises DRb::DRbBadURI when none is registered.
  #: (String uri) -> Socket
  def self.socket(uri)
    link, timeout_ms = @links[uri]
    raise DRb::DRbBadURI, "drbble: no link registered for #{uri}" unless link
    Socket.new(link, timeout_ms)
  end
end

# Extends DRb.create_socket to open DRbBle sockets.
module DRb
  class << self
    alias_method :_ble_base_create_socket, :create_socket

    # Returns a DRbBle socket for "drbble://" URIs and otherwise defers to the original create_socket.
    #: (String uri) -> DRbBle::_Stream
    def create_socket(uri)
      uri.to_s.start_with?("drbble://") ? DRbBle.socket(uri.to_s) : _ble_base_create_socket(uri)
    end
  end
end
