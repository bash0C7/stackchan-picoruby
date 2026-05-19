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
    @writes << bytes
  end

  def read(n, timeout_ms: 0)
    return nil if @pending_rx.empty?
    take = [@pending_rx.length, n].min
    chunk = @pending_rx.shift(take)
    chunk
  end

  def gets
    item = @read_queue.shift
    return nil if item.nil? || item == :timeout
    item[:bytes].pack('C*')
  end
end
