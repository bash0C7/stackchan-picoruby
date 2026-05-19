require "drb/drb"
require "drb/unix"

module StackchanNotifier
  module CliBase
    EXIT_OK      = 0
    EXIT_BAD_ARG = 2

    SWALLOWED_ERRORS = [
      DRb::DRbConnError,
      Errno::ENOENT,
      Errno::ECONNREFUSED,
      Errno::EACCES,
    ].freeze

    module_function

    def drb_send(socket, tuple)
      DRb.start_service
      DRbObject.new_with_uri("drbunix:#{socket}").write(tuple)
    end

    def try_send(sender:, socket:, tuple:, stderr:, quiet:, program_name:)
      sender.call(socket, tuple)
    rescue *SWALLOWED_ERRORS => e
      return if quiet
      stderr.puts "#{program_name}: daemon unavailable (#{e.class}: #{e.message})"
    end
  end
end
