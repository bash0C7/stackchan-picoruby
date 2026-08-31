# App-level robustness patches for the PicoRuby socket / drb stack. The gems
# themselves are upstream picoruby and stay untouched.
#
# Both patches close the same gap: the POSIX socket port hands every failing
# syscall to Ruby with errno discarded, and neither connect nor read is
# retried, so one transient interruption looks exactly like a dead peer.
#
#   connect  SocketError "... Interrupted system call" — a signal (e.g. the
#            scheduler's SIGALRM tick, or SIGCHLD from an unrelated child)
#            landing mid-connect. picoruby-drb opens a fresh socket per remote
#            call, so every call is exposed.
#   read     RuntimeError "read failed" — ports/posix/tcp_socket.c returns -1
#            for every recv() error and src/mruby/tcp_socket.c raises that one
#            message. Observed live 2026-08-31 as a relayed server-side error
#            ("RuntimeError: RuntimeError: read failed"): the daemon failed to
#            read a request it therefore never dispatched, stayed healthy, and
#            served the next call, but the CLI has no resilience and a
#            long-running loop (touch listen, demo) died on it.
#
# A recv() that fails consumes no bytes, so re-issuing the same readpartial is
# lossless — unlike a retry one layer up, which would re-read from the middle
# of a message. A peer that is genuinely gone fails again and the error
# surfaces as before, after a bounded wait.
#
# Loaded by every boot script (boot_cli / boot_daemon / boot_daemon_real /
# boot_daemon_touchtest), each of which requires "drb" first. Both patches are
# guarded on the constants they extend so this file also loads on a VM that has
# neither (the picotest host VM), leaving SocketReadRetry testable on its own.

module SocketReadRetry
  MESSAGE     = "read failed"
  MAX_RETRIES = 3
  BACKOFF_MS  = 5

  # Runs the block, replaying it on the errno-less read failure above.
  # sleep_fn / warn_fn are injection points for the tests; unset, the backoff
  # is a real sleep and the warning goes to stderr (the daemon's stderr is
  # daemon.log, so a retry that fires leaves a trace to correlate against).
  # `raise e`, never a bare `raise`: PicoRuby does not re-raise $! from inside a
  # rescue the way CRuby does — it raises a fresh RuntimeError with an empty
  # message, which would erase the very error the caller needs to read.
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

  def self.warn_default(retries)
    $stderr.write("[socket] transient read failure, retry #{retries}/#{MAX_RETRIES}\n")
  end
end

if Object.const_defined?(:TCPSocket) && !TCPSocket.method_defined?(:_readpartial_without_retry)
  class TCPSocket
    alias_method :_readpartial_without_retry, :readpartial

    def readpartial(maxlen)
      SocketReadRetry.call { _readpartial_without_retry(maxlen) }
    end
  end
end

if Object.const_defined?(:DRb)
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
            raise e
          end
        end
      end
    end
  end
end
