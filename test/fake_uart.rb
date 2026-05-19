class FakeUART
  attr_reader :writes
  attr_accessor :read_queue

  def initialize
    @writes     = []
    @read_queue = []   # each element: { bytes: [..], delay_ms: 0 } or :timeout
  end

  def write(bytes)
    @writes << bytes
  end

  def read(n, timeout_ms: 0)
    item = @read_queue.shift
    return nil if item.nil? || item == :timeout
    bytes = item[:bytes]
    return nil if bytes.empty?
    bytes.first(n)
  end

  def gets
    item = @read_queue.shift
    return nil if item.nil? || item == :timeout
    item[:bytes].pack('C*')
  end
end
