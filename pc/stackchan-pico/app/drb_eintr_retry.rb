# Retries a socket read that fails with a transient read failure.
module SocketReadRetry
  MESSAGE     = "read failed"
  MAX_RETRIES = 3
  BACKOFF_MS  = 5

  # Yields the block, retrying up to MAX_RETRIES times when it raises the transient read failure. Re-raises any other error.
  #: [T] (?sleep_fn: (^(Integer) -> void)?, ?warn_fn: (^(Integer) -> void)?) { () -> T } -> T
  def self.call(sleep_fn: nil, warn_fn: nil)
    retries = 0
    begin
      yield
    rescue RuntimeError => e
      raise e unless e.message == MESSAGE
      retries += 1
      raise e if MAX_RETRIES < retries
      warn_fn ? warn_fn.call(retries) : warn_default(retries)
      sleep_fn ? sleep_fn.call(BACKOFF_MS) : sleep_ms(BACKOFF_MS)
      retry
    end
  end

  # Writes the retry count to stderr.
  #: (Integer retries) -> void
  def self.warn_default(retries)
    $stderr.write("[socket] transient read failure, retry #{retries}/#{MAX_RETRIES}\n")
  end
end

if Object.const_defined?(:TCPSocket)
  # TCPSocket whose readpartial retries a transient read failure.
  class TCPSocket
    alias_method :_readpartial_without_retry, :readpartial

    # Reads up to maxlen bytes, retrying a transient read failure.
    #: (Integer maxlen) -> String
    def readpartial(maxlen)
      SocketReadRetry.call { _readpartial_without_retry(maxlen) }
    end
  end
end

if Object.const_defined?(:DRb)
  # DRb with a create_socket that retries an interrupted connect.
  module DRb
    class << self
      alias_method :_create_socket_without_eintr_retry, :create_socket

      # Opens the DRb socket for uri, retrying up to 5 times when the call is interrupted.
      #: (String uri) -> untyped
      def create_socket(uri)
        tries = 0
        begin
          _create_socket_without_eintr_retry(uri)
        rescue => e
          if e.message.to_s.include?("Interrupted") && (tries += 1) <= 5
            retry
          end
          raise e
        end
      end
    end
  end
end
