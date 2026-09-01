class FakeUART
  attr_reader :writes
  attr_accessor :read_queue
  attr_accessor :pending_rx   # bytes that drain_rx should consume
  attr_accessor :read_queue_after_writes  # hash: { write_count => [{ bytes: [...] }, ...] }

  def initialize(echo: false)
    @writes      = []
    @read_queue  = []           # each element: { bytes: [..], delay_ms: 0 } or :timeout
    @pending_rx  = []           # flat array of bytes consumed by readpartial(n)
    @echo        = echo         # when true, TX bytes loop back on RX (half-duplex sim).
                                # false = no loopback (ESP32-S3 UART1); pass echo: true for half-duplex tests
    @read_queue_after_writes = {} # indexed by write count; values are arrays of queue items
  end

  def write(bytes)
    byte_array = bytes.is_a?(String) ? bytes.bytes : bytes
    @writes << byte_array
    # echo: true loops TX bytes back on RX (half-duplex TTL bus).
    @pending_rx.concat(byte_array) if @echo
    if @read_queue_after_writes && (queued = @read_queue_after_writes[@writes.length])
      queued.each { |item| @read_queue << item }
    end
  end

  def clear_rx_buffer
    @pending_rx.clear
  end

  def flush
  end

  def readpartial(n)
    if @pending_rx.empty? && !@read_queue.empty?
      item = @read_queue.shift
      return nil if item == :timeout
      @pending_rx.concat(item[:bytes])
    end
    return nil if @pending_rx.empty?
    take = [@pending_rx.length, n].min
    chunk_array = @pending_rx.shift(take)
    chunk_array.pack('C*')
  end

  def gets
    item = @read_queue.shift
    return nil if item.nil? || item == :timeout
    item[:bytes].pack('C*')
  end
end
