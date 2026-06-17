# Host fake for picoruby I2C. Mirrors the device API used in application.rb:
#   write(addr, reg, value)         -> records [addr, [reg, value]]
#   read(addr, len, reg, timeout:)  -> returns a `len`-byte String (or nil)
# Scripted reads return one byte each (Integer 0..255), or nil to simulate a
# failed read. Unscripted reads return zero bytes.
class FakeI2C
  attr_reader :writes, :reads

  def initialize
    @writes   = []
    @reads    = []
    @scripted = []
  end

  def write(addr, *data)
    @writes << [addr, data]
    data.size
  end

  def read(addr, len, *params, **_opts)
    @reads << [addr, len, params]
    return ("\x00".b * len) if @scripted.empty?
    v = @scripted.shift
    v.nil? ? nil : [v].pack('C')
  end

  # Script successive OUTPUT1 byte values (Integer), or nil for a failed read.
  def script_reads(*byte_values)
    byte_values.each { |b| @scripted << b }
  end
end
