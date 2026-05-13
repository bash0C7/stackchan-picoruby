# A test double for tenderlove/uart's IO-like object. Records writes, returns
# pre-loaded bytes from #read, and lets the test choose whether #wait_readable
# reports data ready.
class FakeUart
  attr_reader :writes, :wait_readable_calls
  attr_accessor :read_buffer

  def initialize(read_bytes: "")
    @writes = []
    @read_buffer = read_bytes.dup
    @wait_readable_calls = []
    @closed = false
  end

  def write(s)
    @writes << s.to_s
    s.to_s.bytesize
  end

  def read(n)
    bytes = @read_buffer.slice!(0, n)
    bytes.empty? ? nil : bytes
  end

  # Returns self when there's at least one byte buffered, nil otherwise.
  # The `timeout` argument is recorded for assertion; it does not sleep.
  def wait_readable(timeout)
    @wait_readable_calls << timeout
    @read_buffer.empty? ? nil : self
  end

  def close
    @closed = true
  end

  def closed?
    @closed
  end
end
