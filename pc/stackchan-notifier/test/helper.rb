require "bundler/setup"
require "test/unit"

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

# Fake BLE client used by Worker tests. Records every send and lets tests
# script connect / send behavior (raise to simulate disconnect, etc.).
class FakeBleClient
  attr_reader :sent, :connect_count, :disconnect_count

  def initialize
    @sent = []
    @connect_count = 0
    @disconnect_count = 0
    @on_connect = nil
    @on_send = nil
  end

  def on_connect(&block); @on_connect = block; end
  def on_send(&block); @on_send = block; end

  def connect
    @connect_count += 1
    @on_connect&.call(self)
    self
  end

  def send
    builder = FakeSendBuilder.new
    yield builder
    @on_send&.call(builder)
    @sent << builder.commands
    self
  end

  def disconnect
    @disconnect_count += 1
    self
  end
end

class FakeSendBuilder
  attr_reader :commands
  def initialize
    @commands = []
  end
  def face(name)
    @commands << { kind: :face, name: name }
  end
  def led(form, value = nil, side: :both, mode: :solid)
    @commands << { kind: :led, form: form, value: value, side: side, mode: mode }
  end
end
