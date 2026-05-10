class FakeSPI
  attr_reader :writes
  attr_accessor :dc_pin  # optional FakeGPIO observer; when set, commands (DC=0) are also recorded into @command_bytes

  def initialize
    @writes = []
    @command_bytes = []
    @command_positions = []  # writes[] index of each command byte
  end

  # Bytes written while @dc_pin is LOW. Requires dc_pin= to have been wired up
  # before the writes occurred. Used to assert command-vs-data semantics
  # without conflating literal data bytes (e.g. gamma payload) that happen to
  # match a command opcode like 0x36 (MADCTL).
  def command_bytes
    @command_bytes
  end

  # writes[]-index of each command byte in @command_bytes (parallel array).
  # command_positions[k] is the position in @writes of the k-th command byte.
  def command_positions
    @command_positions
  end

  def write(*data)
    flat = data.flat_map { |d| coerce(d) }
    if @dc_pin && @dc_pin.value == 0
      flat.each_with_index do |b, j|
        @command_positions << (@writes.size + j)
        @command_bytes << b
      end
    end
    @writes.concat(flat)
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
    @command_bytes = []
    @command_positions = []
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
