# dRuby over BLE. The bytes on the air are exactly DRb's TCP stream (4-byte
# big-endian length + Marshal per field), cut into chunks no larger than one
# ATT write / notification. ATT is ordered and reliable within a connection, so
# no extra envelope is needed.
#
# The peripheral runs a non-blocking DRbBle::Responder fed from its own tick;
# the central talks through DRb::DRbObject with a `drbble://<name>` URI whose
# link was registered with DRbBle.register.
begin
  require 'drb'
rescue LoadError
  # No picoruby-drb in this VM: the transport below stays unhooked.
end

module DRbBle
  CHUNK = 180   # darwin exposes no MTU; the NUS writes already use 180 B

  class Incomplete < StandardError; end

  # Splits data into byteslices of at most size bytes.
  def self.chunks(data, size = CHUNK)
    out = []
    pos = 0
    len = data.bytesize
    while pos < len
      out << data.byteslice(pos, size)
      pos += size
    end
    out
  end

  # socket#read over a String; raises Incomplete when the bytes are not there yet.
  class BufferReader
    def initialize(buf)
      @buf = buf
      @pos = 0
    end

    attr_reader :pos

    def read(n)
      raise Incomplete if @pos + n > @buf.bytesize
      s = @buf.byteslice(@pos, n)
      @pos += n
      s
    end
  end

  # socket#write into a String.
  class BufferWriter
    def initialize
      @out = ""
    end

    attr_reader :out

    def write(s)
      @out << s
      s.bytesize
    end
  end

  # Server side. feed takes whatever one BLE write delivered and returns the
  # reply bytes of every request it completed ("" when none). Only the method
  # names in allow can be called: any central in range can write to it.
  class Responder
    def initialize(front, allow:)
      @front = front
      @allow = allow
      @buf = ""
    end

    def pending_bytes
      @buf.bytesize
    end

    # A central that went away mid-request leaves a partial one behind.
    def reset
      @buf = ""
    end

    def feed(bytes)
      @buf << bytes
      out = ""
      while true
        reader = BufferReader.new(@buf)
        begin
          req = DRb::DRbMessage.new(reader).recv_request
        rescue Incomplete
          break
        end
        @buf = @buf.byteslice(reader.pos, @buf.bytesize - reader.pos) || ""
        out << reply_for(req[0], req[1], req[2])
      end
      out
    end

    private

    def reply_for(ref, msg_id, args)
      writer = BufferWriter.new
      message = DRb::DRbMessage.new(writer)
      if !ref.nil?
        message.send_reply(false, "DRb::DRbError: no object #{ref.inspect}")
      elsif !@allow.include?(msg_id)
        message.send_reply(false, "NoMethodError: #{msg_id} is not exposed")
      else
        begin
          message.send_reply(true, @front.send(msg_id, *args))
        rescue => e
          message.send_reply(false, "#{e.class}: #{e.message}")
        end
      end
      writer.out
    end
  end

  # Client side: the socket DRb.send_message talks to. Writes are held until
  # the first read so one request goes out as few chunks as possible.
  #
  # link: send_chunk(bytes) / poll -> String or nil (bytes the peer notified)
  class ClientSocket
    POLL_MS = 20

    def initialize(link, timeout_ms: 3000, chunk: CHUNK)
      @link = link
      @timeout_ms = timeout_ms
      @chunk = chunk
      @tx = ""
      @rx = ""
    end

    def write(s)
      @tx << s
      s.bytesize
    end

    def read(n)
      flush
      waited = 0
      while @rx.bytesize < n
        data = @link.poll
        if data
          @rx << data
        else
          raise DRb::DRbConnError, "drbble: no reply in #{@timeout_ms} ms" if waited >= @timeout_ms
          sleep_ms POLL_MS
          waited += POLL_MS
        end
      end
      s = @rx.byteslice(0, n)
      @rx = @rx.byteslice(n, @rx.bytesize - n) || ""
      s
    end

    # DRb.send_message closes after every call; the BLE link stays up.
    def close
      @tx = ""
      @rx = ""
    end

    private

    def flush
      return if @tx.empty?
      parts = DRbBle.chunks(@tx, @chunk)
      i = 0
      while i < parts.length
        @link.send_chunk(parts[i])
        i += 1
      end
      @tx = ""
    end
  end

  @links = {}

  def self.register(uri, link, timeout_ms: 3000)
    @links[uri] = [link, timeout_ms]
  end

  def self.unregister(uri)
    @links.delete(uri)
  end

  def self.socket_for(uri)
    entry = @links[uri]
    raise DRb::DRbBadURI, "drbble: no link registered for #{uri}" unless entry
    ClientSocket.new(entry[0], timeout_ms: entry[1])
  end
end

# A device firmware without picoruby-drb still loads this file (app.mrb bundles it).
if Object.const_defined?(:DRb)
  module DRb
    class << self
      alias_method :_ble_base_create_socket, :create_socket

      def create_socket(uri)
        if uri.to_s.start_with?("drbble://")
          DRbBle.socket_for(uri.to_s)
        else
          _ble_base_create_socket(uri)
        end
      end
    end
  end
end
