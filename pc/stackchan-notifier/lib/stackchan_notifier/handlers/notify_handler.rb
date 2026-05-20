require_relative "../notify_motion_table"

module StackchanNotifier
  module Handlers
    class NotifyHandler
      def initialize
        @restore_thread = nil
      end

      def deliver(client:, params:, ctx:)
        cancel_pending_restore
        client.send do |s|
          s.face(params[:face])
          s.led(:hsb, params[:left][0],  side: :left,  mode: params[:left][1])
          s.led(:hsb, params[:right][0], side: :right, mode: params[:right][1])
          unless params[:silent]
            motion = NotifyMotionTable.lookup(params[:face])
            if motion
              s.head(
                yaw_left:  motion[:yaw_left],
                yaw_right: motion[:yaw_right],
                pitch_up:  motion[:pitch_up],
                time_ms:   motion[:time_ms],
                velocity:  nil,
              )
            end
          end
        end
        if params[:duration] && params[:duration] > 0
          schedule_restore(ctx, params[:duration], silent: params[:silent])
        end
      end

      private

      def schedule_restore(ctx, seconds, silent:)
        ts        = ctx[:ts]
        sleep_fn  = ctx[:restore_sleep_fn]
        @restore_thread = Thread.new(ts, seconds, silent, sleep_fn) do |t, secs, sil, sf|
          sf.call(secs)
          t.write([:cmd, :notify, {
            face: :neutral,
            left:  [0x000000, :solid],
            right: [0x000000, :solid],
            duration: nil,
            silent: sil,
          }])
        end
      end

      def cancel_pending_restore
        @restore_thread&.kill
        @restore_thread = nil
      end
    end
  end
end
