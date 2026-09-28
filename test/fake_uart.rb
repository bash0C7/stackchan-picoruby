class FakeUART
  attr_reader :writes
  attr_accessor :read_queue
  attr_accessor :pending_rx
  attr_accessor :read_queue_after_writes

  def initialize
    @writes      = []
    @read_queue  = []
    @pending_rx  = []
    @read_queue_after_writes = {}
  end

  def write(bytes)
    byte_array = bytes.is_a?(String) ? bytes.bytes : bytes
    @writes << byte_array
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
