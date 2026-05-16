$LOAD_PATH.unshift File.expand_path("../mrblib", __dir__)
$LOAD_PATH.unshift File.expand_path(".", __dir__)

# PicoRuby shim: 'i2c' is a runtime built-in. Mark loaded for host tests.
$LOADED_FEATURES << "i2c" unless $LOADED_FEATURES.include?("i2c")

require "test/unit"

class FakeI2C
  attr_reader :writes, :reads

  def initialize
    @writes = []
    @reads = []
    @read_queue = []
    @raise_on_write = nil
    @raise_on_read = nil
    @write_returns = nil
  end

  attr_accessor :raise_on_write, :raise_on_read, :write_returns

  def queue_read(bytes)
    @read_queue << bytes
  end

  def write(addr, *args, **opts)
    raise @raise_on_write if @raise_on_write
    @writes << { addr: addr, args: args, opts: opts }
    @write_returns || args.flatten.size
  end

  def read(addr, length, reg = nil, **opts)
    raise @raise_on_read if @raise_on_read
    @reads << { addr: addr, length: length, reg: reg, opts: opts }
    @read_queue.shift || ("\x00".b * length)
  end
end

require "py32_io_expander"
