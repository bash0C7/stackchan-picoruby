class FakeSPI
  attr_reader :writes

  def initialize
    @writes = []
  end

  def write(*data)
    @writes.concat(data.flat_map { |d| coerce(d) })
    data.size
  end

  def select
    yield self
    deselect
  end

  def deselect
    @writes << :deselect
  end

  def transfer(*data, additional_read_bytes: 0)
    @writes.concat(data.flat_map { |d| coerce(d) })
    "\x00".b * (data.size + additional_read_bytes)
  end

  def read(length, _repeated_tx_data = 0)
    "\x00".b * length
  end

  def reset_log!
    @writes = []
  end

  private

  def coerce(d)
    case d
    when Integer then [d & 0xFF]
    when String  then d.bytes
    when Array   then d.flat_map { |x| coerce(x) }
    else
      raise ArgumentError, "FakeSPI cannot coerce #{d.class}"
    end
  end
end
