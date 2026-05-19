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

# Records each #write call as a separate frame entry.
# Use #frames to assert on whole-frame writes.
# #history (back-compat) returns all frames concatenated.
class FakeStdio
  attr_reader :frames

  def initialize
    @frames = []
  end

  def write(s)
    @frames << s.to_s
    s.to_s.bytesize
  end

  # Back-compat: concatenated string of all written frames.
  def history
    @frames.join
  end
end

# Alias for tests that still reference FakeStdout.
FakeStdout = FakeStdio
