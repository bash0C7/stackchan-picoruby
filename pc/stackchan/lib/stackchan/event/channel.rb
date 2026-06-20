require "thread"

module Stackchan
  module Event
    class Channel
      def initialize
        @queue = Queue.new
      end

      def push(event)
        @queue << event
      end

      def pop(timeout: nil)
        timeout ? @queue.pop(timeout: timeout) : @queue.pop
      end

      def each
        loop { yield @queue.pop }
      end
    end
  end
end
