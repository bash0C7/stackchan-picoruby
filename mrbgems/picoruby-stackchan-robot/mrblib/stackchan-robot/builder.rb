module StackChan
  class Robot
    class Builder
      TOUCH_ZONES = { back: 0, right: 1, left: 2 }

      def initialize(robot)
        @robot = robot
      end

      def face(name, **geometry)
        @robot.faces[name] = Face.new(**geometry)
      end

      def face_index(map)
        keys = map.keys
        i = 0
        while i < keys.size
          @robot.face_index[keys[i]] = map[keys[i]]
          i += 1
        end
      end

      def on_boot(&handler)
        require_block(:on_boot, handler)
        @robot.boot_handlers << handler
      end

      def on_touch(zone, &handler)
        require_block(:on_touch, handler)
        index = TOUCH_ZONES[zone]
        raise ArgumentError, "on_touch: zone must be :back, :right or :left, got #{zone.inspect}" unless index
        @robot.touch_handlers[index] = handler
      end

      def on_frame(key, &handler)
        require_block(:on_frame, handler)
        raise ArgumentError, "on_frame: key must be a String, got #{key.inspect}" unless key.is_a?(String)
        if Dispatcher::FRAME_KEYS.include?(key) || Dispatcher::SYSTEM_KEYS.include?(key)
          raise ArgumentError, "on_frame: #{key.inspect} is an engine frame key"
        end
        @robot.frame_handlers[key] = handler
      end

      def remote(name, &handler)
        require_block(:remote, handler)
        raise ArgumentError, "remote: name must be a Symbol, got #{name.inspect}" unless name.is_a?(Symbol)
        if Remote.new(nil).respond_to?(name, true)
          raise ArgumentError, "remote: #{name.inspect} is already a method of the dRuby front"
        end
        @robot.remote_handlers[name] = handler
      end

      def every(ms, &handler)
        require_block(:every, handler)
        unless ms.is_a?(Integer) && ms > 0
          raise ArgumentError, "every: period must be a positive Integer of ms, got #{ms.inspect}"
        end
        @robot.periodic << [ms, handler]
      end

      def release_after(ms)
        unless ms.is_a?(Integer) && ms > 0
          raise ArgumentError, "release_after: must be a positive Integer of ms, got #{ms.inspect}"
        end
        @robot.release_after = ms
      end

      private

      def require_block(name, handler)
        raise ArgumentError, "#{name} needs a block" unless handler
      end
    end
  end
end
