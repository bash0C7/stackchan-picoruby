module StackChan
  class Robot
    # Receiver of the StackChan.robot block; each method records one definition on the Robot.
    class Builder
      TOUCH_ZONES = { back: 0, right: 1, left: 2 }
      ENGINE_FRAME_KEYS = %w[torque selftest read F L text YL YR PU T V M S R G B A]

      # Binds the builder to the Robot it fills.
      #: (Robot robot) -> void
      def initialize(robot)
        @robot = robot
      end

      # Defines face name from Face.new keywords and returns it.
      #: (Symbol name, ?eyes: Symbol, ?mouth: (Symbol | Integer), ?brows: Symbol?) -> Face
      def face(name, **geometry)
        @robot.faces[name] = Face.new(**geometry)
      end

      # Merges map (frame F value to face name) into the robot's face index.
      #: (Hash[String, Symbol] map) -> void
      def face_index(map)
        keys = map.keys
        i = 0
        while i < keys.size
          @robot.face_index[keys[i]] = map[keys[i]]
          i += 1
        end
      end

      # Registers a handler called with the handle once before advertising. Raises ArgumentError without a block.
      #: () { (Handle) -> void } -> void
      def on_boot(&handler)
        require_block(:on_boot, handler)
        @robot.boot_handlers << handler
      end

      # Registers the handler for a head touch zone (:back, :right or :left). Raises ArgumentError for another zone or no block.
      #: (Symbol zone) { (Handle) -> void } -> void
      def on_touch(zone, &handler)
        require_block(:on_touch, handler)
        index = TOUCH_ZONES[zone]
        raise ArgumentError, "on_touch: zone must be :back, :right or :left, got #{zone.inspect}" unless index
        @robot.touch_handlers[index] = handler
      end

      # Registers a handler for a frame key; its truthy result means ACK.
      # Raises ArgumentError for a non-String key, an engine frame key or no block.
      #: (String key) { (Handle, String) -> bool } -> void
      def on_frame(key, &handler)
        require_block(:on_frame, handler)
        raise ArgumentError, "on_frame: key must be a String, got #{key.inspect}" unless key.is_a?(String)
        raise ArgumentError, "on_frame: #{key.inspect} is an engine frame key" if ENGINE_FRAME_KEYS.include?(key)
        @robot.frame_handlers[key] = handler
      end

      # Exposes a dRuby front method name backed by the handler.
      # Raises ArgumentError for a non-Symbol name, a name the front already defines or no block.
      #: (Symbol name) { (Handle, *untyped) -> untyped } -> void
      def remote(name, &handler)
        require_block(:remote, handler)
        raise ArgumentError, "remote: name must be a Symbol, got #{name.inspect}" unless name.is_a?(Symbol)
        if Remote.new(nil).respond_to?(name, true)
          raise ArgumentError, "remote: #{name.inspect} is already a method of the dRuby front"
        end
        @robot.remote_handlers[name] = handler
      end

      # Registers a handler run every ms milliseconds. Raises ArgumentError unless ms is a positive Integer or no block.
      #: (Integer ms) { (Handle) -> void } -> void
      def every(ms, &handler)
        require_block(:every, handler)
        unless ms.is_a?(Integer) && ms > 0
          raise ArgumentError, "every: period must be a positive Integer of ms, got #{ms.inspect}"
        end
        @robot.periodic << [ms, handler]
      end

      # Sets how long the link may stay silent before the central is released.
      # Raises ArgumentError unless ms is a positive Integer.
      #: (Integer ms) -> void
      def release_after(ms)
        unless ms.is_a?(Integer) && ms > 0
          raise ArgumentError, "release_after: must be a positive Integer of ms, got #{ms.inspect}"
        end
        @robot.release_after = ms
      end

      private

      # Raises ArgumentError naming the DSL method when handler is nil.
      #: (Symbol name, Proc? handler) -> void
      def require_block(name, handler)
        raise ArgumentError, "#{name} needs a block" unless handler
      end
    end
  end
end
