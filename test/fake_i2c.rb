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

  def read(addr, len, *params)
    @reads << [addr, len, params]
    return ("\x00" * len) if @scripted.empty?
    [@scripted.shift].pack('C*')
  end

  def script_reads(*byte_values)
    byte_values.each { |b| @scripted << b }
  end
end
