# Returns bytes one at a time via #read(1). Returns nil when bytes are exhausted
# — Dispatcher#run uses that as end-of-stream signal so tests don't hang.
class FakeStdin
  def initialize(bytes_string)
    @buffer = bytes_string.dup
  end

  def read(n)
    return nil if @buffer.empty?
    raise ArgumentError, "FakeStdin only supports read(1)" unless n == 1
    @buffer.slice!(0, 1)
  end
end

# Records #write history. Each entry is the string passed (1-byte expected).
class FakeStdout
  attr_reader :writes

  def initialize
    @writes = []
  end

  def write(s)
    @writes << s.to_s
    s.to_s.bytesize
  end
end
