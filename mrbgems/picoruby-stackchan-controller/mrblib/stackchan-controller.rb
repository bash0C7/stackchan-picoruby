# Namespace of the StackChan controller; StackChan.controller builds a Controller from a DSL block.
module StackChan
  # Builds a Controller by yielding a Controller::Builder to the block.
  # Raises ArgumentError when no block is given.
  #: () { (Controller::Builder) -> void } -> Controller
  def self.controller
    raise ArgumentError, "StackChan.controller needs a block" unless block_given?
    controller = Controller.new
    yield Controller::Builder.new(controller)
    controller
  end

  # Declared actions, touch/reply handlers and periodic jobs of one controller application, wired to a Daemon on first use.
  class Controller
    # @rbs @declared: Hash[Symbol, Hash[Symbol, untyped]]
    # @rbs @touch_handlers: Array[Proc]
    # @rbs @reply_handlers: Array[Proc]
    # @rbs @periodic: Array[[Integer, Proc]]
    # @rbs @hold_ms: Integer?
    # @rbs @daemon: Daemon?
    # @rbs @out: ^(String) -> void

    BUILTINS = [:connect, :status, :stop, :raw, :calibrate, :speak_audio]
    BUTTONS  = [:connect, :status, :stop]

    attr_reader :declared #: Hash[Symbol, Hash[Symbol, untyped]]
    attr_reader :touch_handlers #: Array[Proc]
    attr_reader :reply_handlers #: Array[Proc]
    attr_reader :periodic #: Array[[Integer, Proc]]
    attr_accessor :hold_ms #: Integer?

    # Returns [name, label] pairs for the button built-ins (label nil) followed by the declared actions.
    #: (Hash[Symbol, Hash[Symbol, untyped]] declared) -> Array[[Symbol, String?]]
    def self.listing(declared)
      list = BUTTONS.map { |name| [name, nil] }
      declared.each { |name, entry| list << [name, entry[:label]] }
      list
    end

    # Creates an empty controller and defines the built-in actions as methods.
    #: () -> void
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

    # Builds the Link and Daemon over the given central, registers the touch, reply and periodic handlers, and returns the Daemon.
    #: (central: untyped, ?voice: untyped, ?clock: ^() -> Integer, ?log: ^(String) -> void, ?port: Integer, ?host: String, ?out: ^(String) -> void) -> Daemon
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

    # Starts the daemon over a BLE central (a fake one when name_prefix is "fake") with a dRuby sidecar voice, and blocks until it stops.
    #: (port: Integer, ?host: String, ?name_prefix: String, ?sidecar_uri: String) -> void
    def serve(port:, host: "127.0.0.1", name_prefix: "StackChan", sidecar_uri: "druby://127.0.0.1:8788")
      central = name_prefix == "fake" ? FakeBleClient.new : Central.new(name_prefix: name_prefix)
      log = ->(line) { $stderr.write("[stackchand] #{line}\n"); $stderr.flush }
      daemon = wire(central: central, voice: DRb::DRbObject.new_with_uri(sidecar_uri), log: log, port: port, host: host)
      daemon.start
      daemon.join
    end

    # Runs the named action on the wired daemon and returns its result Hash (:status is :ok, :busy or :error).
    #: (Symbol name, ?untyped arg) -> Hash[Symbol, untyped]
    def act(name, arg = nil)
      wired.act(name, arg)
    end

    # Returns the [name, label] action list; with an argument, also writes one "name<TAB>label" line per action.
    #: (?String? arg) -> Array[[Symbol, String?]]
    def actions(arg = nil)
      list = Controller.listing(@declared)
      list.each { |name, label| @out.call("#{name}\t#{label || name}") } unless arg.nil?
      list
    end

    # Runs one daemon tick on the wired daemon.
    #: (?String? _arg) -> untyped
    def tick(_arg = nil)
      wired.tick
    end

    # Defines a singleton method named name that runs the action and prints its result.
    #: (Symbol name) -> void
    def define_action(name)
      singleton_class_of.define_method(name) { |arg = nil| run_action(name, arg) }
    end

    private

    # Returns the singleton class of this controller.
    #: () -> Class
    def singleton_class_of
      class << self
        self
      end
    end

    # Runs the action, writes "busy: ..." or "error: ..." for a non-ok status or the output for an ok one, and returns the result.
    #: (Symbol name, String? arg) -> Hash[Symbol, untyped]
    def run_action(name, arg)
      result = act(name, arg)
      case result[:status]
      when :ok      then print_out(result[:out])
      when :busy    then @out.call("busy: #{result[:message]}")
      else               @out.call("error: #{result[:message]}")
      end
      result
    end

    # Returns the wired daemon, wiring a default Central on first use.
    #: () -> Daemon
    def wired
      return @daemon if @daemon
      log = ->(line) { puts line }
      wire(central: Central.new(log_fn: log), log: log)
    end

    # Writes an Array as one line per element, a Hash as one key=value line, anything else non-nil as its string form.
    #: (untyped value) -> void
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
