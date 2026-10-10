module StackChan
  class Controller
    class Builder
      def initialize(controller)
        @controller = controller
      end

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

      def on_touch(&handler)
        require_block(:on_touch, handler)
        @controller.touch_handlers << handler
      end

      def on_reply(&handler)
        require_block(:on_reply, handler)
        @controller.reply_handlers << handler
      end

      def every(ms, &handler)
        require_block(:every, handler)
        unless ms.is_a?(Integer) && ms > 0
          raise ArgumentError, "every: period must be a positive Integer of ms, got #{ms.inspect}"
        end
        @controller.periodic << [ms, handler]
      end

      def hold(ms)
        unless ms.is_a?(Integer) && ms > 0
          raise ArgumentError, "hold: must be a positive Integer of ms, got #{ms.inspect}"
        end
        @controller.hold_ms = ms
      end

      private

      def require_block(name, handler)
        raise ArgumentError, "#{name} needs a block" unless handler
      end
    end
  end
end
