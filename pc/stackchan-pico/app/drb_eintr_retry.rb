# App-level robustness patch (does NOT touch the picoruby-drb gem). PicoRuby's
# socket connect does not restart on EINTR, so a signal (e.g. SIGCHLD from an
# unrelated child) can surface as `SocketError: ... Interrupted system call`
# mid-connect. picoruby-drb opens a fresh socket per remote call, so wrap
# DRb.create_socket to retry a few times on that transient.
require "drb"

module DRb
  class << self
    unless method_defined?(:_create_socket_without_eintr_retry) || respond_to?(:_create_socket_without_eintr_retry)
      alias_method :_create_socket_without_eintr_retry, :create_socket

      def create_socket(uri)
        tries = 0
        begin
          _create_socket_without_eintr_retry(uri)
        rescue => e
          if e.message.to_s.include?("Interrupted") && (tries += 1) <= 5
            retry
          end
          raise
        end
      end
    end
  end
end
