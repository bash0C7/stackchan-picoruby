require "bundler/setup"
require "test/unit"
require "logger"
require "stringio"
require "fileutils"

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

def wait_until(timeout: 1.0)
  deadline = Time.now + timeout
  until yield
    sleep 0.01
    raise "timeout waiting for condition" if Time.now > deadline
  end
end

def build_capturing_logger(sink)
  logger = Logger.new(StringIO.new)
  logger.formatter = ->(_severity, _time, _progname, msg) { sink << msg; "" }
  logger
end

# Captures (severity, msg) pairs so tests can assert on the LEVEL too, not
# just the text. Use this when the test cares whether something was logged
# as INFO vs WARN vs ERROR.
def build_severity_capturing_logger(events)
  logger = Logger.new(StringIO.new)
  logger.formatter = ->(severity, _time, _progname, msg) { events << [severity, msg]; "" }
  logger
end

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

  def raw_send(frame)
    @sent << { kind: :raw_send, frame: frame }
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
  def head(yaw: nil, pitch: nil, time_ms: nil, velocity: nil)
    @commands << { kind: :head, yaw: yaw, pitch: pitch, time_ms: time_ms, velocity: velocity }
  end
end
