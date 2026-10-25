module StackChan
  class Controller
    # The DSL object yielded by StackChan.controller; every method validates its arguments and records them on the Controller.
    class Builder
      # @rbs @controller: Controller

      # Wraps the controller the DSL declarations are recorded on.
      #: (Controller controller) -> void
      def initialize(controller)
        @controller = controller
      end

      # Declares an action and defines it as a method of the controller.
      # Raises ArgumentError for a missing block, a non-Symbol or built-in or already used name, or a bad label or flags.
      #: (Symbol name, ?label: String?, ?flags: Array[String]) { (Session, Args) -> untyped } -> void
      def action(name, label: nil, flags: [], &handler)
        require_block(:action, handler)
        raise ArgumentError, "action: name must be a Symbol, got #{name.inspect}" unless name.is_a?(Symbol)
        raise ArgumentError, "action: #{name.inspect} is a built-in action" if BUILTINS.include?(name)
        if Controller.new.respond_to?(name, true)
          raise ArgumentError, "action: #{name.inspect} is already a method of the controller"
        end
        raise ArgumentError, "action: #{name.inspect} is already declared" if @controller.declared.key?(name)
        raise ArgumentError, "action: label must be a String, got #{label.inspect}" unless label.nil? || label.is_a?(String)
        unless flags.is_a?(Array) && flags.all? { |f| f.is_a?(String) }
          raise ArgumentError, "action: flags must be an Array of Strings, got #{flags.inspect}"
        end
        @controller.declared[name] = { label: label, flags: flags, blk: handler }
        @controller.define_action(name)
      end

      # Registers a handler called for each head touch.
      # Raises ArgumentError without a block.
      #: () { (Session, Symbol?) -> void } -> void
      def on_touch(&handler)
        require_block(:on_touch, handler)
        @controller.touch_handlers << handler
      end

      # Registers a handler called for each reply line.
      # Raises ArgumentError without a block.
      #: () { (Session, String) -> void } -> void
      def on_reply(&handler)
        require_block(:on_reply, handler)
        @controller.reply_handlers << handler
      end

      # Registers a handler run every ms milliseconds.
      # Raises ArgumentError without a block or when ms is not a positive Integer.
      #: (Integer ms) { (Session) -> void } -> void
      def every(ms, &handler)
        require_block(:every, handler)
        unless ms.is_a?(Integer) && ms > 0
          raise ArgumentError, "every: period must be a positive Integer of ms, got #{ms.inspect}"
        end
        @controller.periodic << [ms, handler]
      end

      # Sets how long the link is held after the last action, in milliseconds.
      # Raises ArgumentError when ms is not a positive Integer.
      #: (Integer ms) -> void
      def hold(ms)
        unless ms.is_a?(Integer) && ms > 0
          raise ArgumentError, "hold: must be a positive Integer of ms, got #{ms.inspect}"
        end
        @controller.hold_ms = ms
      end

      private

      # Raises ArgumentError unless handler is given.
      #: (Symbol name, Proc? handler) -> void
      def require_block(name, handler)
        raise ArgumentError, "#{name} needs a block" unless handler
      end
    end
  end
end
