module StackChan
  def self.controller
    raise ArgumentError, "StackChan.controller needs a block" unless block_given?
    controller = Controller.new
    yield Controller::Builder.new(controller)
    controller
  end

  class Controller
    BUILTINS = [:connect, :status, :stop, :raw, :calibrate, :speak_audio]
    BUTTONS  = [:connect, :status, :stop]

    attr_reader :declared, :touch_handlers, :reply_handlers, :periodic
    attr_accessor :hold_ms

    def self.listing(declared)
      list = BUTTONS.map { |name| [name, nil] }
      declared.each { |name, entry| list << [name, entry[:label]] }
      list
    end

    def initialize
      @declared       = {}
      @touch_handlers = []
      @reply_handlers = []
      @periodic       = []
      @hold_ms        = nil
      @daemon         = nil
      @out            = ->(line) { puts line }
      BUILTINS.each { |name| define_action(name) }
    end

    def wire(central:, voice: nil, clock: -> { Machine.board_millis }, log: nil, port: 8787, host: "127.0.0.1",
             out: ->(line) { puts line })
      @out = out
      link = Link.new(central: central, clock: clock, hold: @hold_ms, log: log)
      @daemon = Daemon.new(link: link, central: central, voice: voice, port: port, host: host, sidecar_uri: nil,
                           clock: clock, log: log, actions: @declared)
      @touch_handlers.each { |h| @daemon.on_touch(&h) }
      @reply_handlers.each { |h| @daemon.on_reply(&h) }
      @periodic.each { |ms, h| @daemon.every(ms, &h) }
      @daemon
    end

    def serve(port:, host: "127.0.0.1", name_prefix: "StackChan", sidecar_uri: "druby://127.0.0.1:8788")
      central = name_prefix == "fake" ? FakeBleClient.new : Central.new(name_prefix: name_prefix)
      log = ->(line) { $stderr.write("[stackchand] #{line}\n"); $stderr.flush }
      daemon = wire(central: central, voice: DRb::DRbObject.new_with_uri(sidecar_uri), log: log, port: port, host: host)
      daemon.start
      daemon.join
    end

    def act(name, arg = nil)
      wired.act(name, arg)
    end

    def actions(arg = nil)
      list = Controller.listing(@declared)
      list.each { |name, label| @out.call("#{name}\t#{label || name}") } unless arg.nil?
      list
    end

    def tick(_arg = nil)
      wired.tick
    end

    def define_action(name)
      singleton_class_of.define_method(name) { |arg = nil| run_action(name, arg) }
    end

    private

    def singleton_class_of
      class << self
        self
      end
    end

    def run_action(name, arg)
      result = act(name, arg)
      case result[:status]
      when :ok      then print_out(result[:out])
      when :busy    then @out.call("busy: #{result[:message]}")
      else               @out.call("error: #{result[:message]}")
      end
      result
    end

    def wired
      return @daemon if @daemon
      log = ->(line) { puts line }
      wire(central: Central.new(log_fn: log), log: log)
    end

    def print_out(value)
      if value.is_a?(Array)
        value.each { |line| @out.call(line.to_s.chomp) }
      elsif value.is_a?(Hash)
        @out.call(value.map { |k, v| "#{k}=#{v}" }.join(" "))
      elsif !value.nil?
        @out.call(value.to_s)
      end
    end
    BUILTINS.each do |name|
      raise NameError, "built-in action #{name.inspect} is a method of Controller" if method_defined?(name)
    end
  end
end
