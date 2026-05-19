module StackchanNotifier
  module Handlers
    class ServoHandler
      def deliver(client:, params:, ctx:)
        client.send do |s|
          s.head(
            yaw:      params[:yaw],
            pitch:    params[:pitch],
            time_ms:  params[:time_ms],
            velocity: params[:velocity],
          )
        end
      end
    end
  end
end
