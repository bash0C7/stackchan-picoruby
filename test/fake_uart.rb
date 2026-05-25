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
                                # Default false reflects ESP32-S3 UART1 reality (no
                                # loopback) verified 2026-05-21. Tests that need
                                # half-duplex echo (e.g. read_pos_raw_debug echo path)
                                # must pass echo: true explicitly.
    @read_queue_after_writes = {} # indexed by write count; values are arrays of queue items
  end

  def write(bytes)
    # Production picoruby-uart#write requires String; FakeUART accepts both
    # so test assertions can compare byte arrays directly.
    byte_array = bytes.is_a?(String) ? bytes.bytes : bytes
    @writes << byte_array
    # Half-duplex TTL bus: master's TX bytes echo back on RX immediately (when @echo=true).
    # SCServo#drain_echo reads and discards these before reading the servo response.
    # When @echo=false, TX bytes do not loop back (production no-echo scenario).
    @pending_rx.concat(byte_array) if @echo
    # After recording the write, check if any responses should be queued for this write count.
    if @read_queue_after_writes && (queued = @read_queue_after_writes[@writes.length])
      queued.each { |item| @read_queue << item }
    end
  end

  # Mirrors UART#clear_rx_buffer — drains any stale bytes before a new transaction.
  def clear_rx_buffer
    @pending_rx.clear
  end

  # Mirrors UART#flush — no-op in test double (no real hardware buffer to flush).
  def flush
  end

  # When pending_rx is exhausted, pulls the next read_queue entry into pending_rx.
  # Returns nil for :timeout entries or when no data is available.
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

  # Legacy method for tests that exercised the old signature. Kept for
  # backward compatibility but production SCServo no longer calls it.
  def read(n, timeout_ms: 0)
    readpartial(n)&.bytes
  end

  def gets
    item = @read_queue.shift
    return nil if item.nil? || item == :timeout
    item[:bytes].pack('C*')
  end
end
