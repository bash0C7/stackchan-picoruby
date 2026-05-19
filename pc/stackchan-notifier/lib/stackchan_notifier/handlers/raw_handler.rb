module StackchanNotifier
  module Handlers
    class RawHandler
      def deliver(client:, params:, ctx:)
        frame = params[:frame]
        frame = frame + "\n" unless frame.end_with?("\n")
        client.raw_send(frame)
      end
    end
  end
end
