module StackchanNotifier
  module Handlers
    class ServoHandler
      def deliver(client:, params:, ctx:)
        client.send do |s|
          s.head(
            yaw_left:  params[:yaw_left],
            yaw_right: params[:yaw_right],
            pitch_up:  params[:pitch_up],
            time_ms:   params[:time_ms],
            velocity:  params[:velocity],
          )
        end
      end
    end
  end
end
