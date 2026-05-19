class FakeUART
  attr_reader :writes
  attr_accessor :read_queue
  attr_accessor :pending_rx   # bytes that drain_rx should consume

  def initialize
    @writes      = []
    @read_queue  = []           # each element: { bytes: [..], delay_ms: 0 } or :timeout
    @pending_rx  = []           # flat array of bytes consumed by read(n, ...)
  end

  def write(bytes)
    # Production picoruby-uart#write requires String; FakeUART accepts both
    # so test assertions can compare byte arrays directly.
    @writes << (bytes.is_a?(String) ? bytes.bytes : bytes)
  end

  def readpartial(n)
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
