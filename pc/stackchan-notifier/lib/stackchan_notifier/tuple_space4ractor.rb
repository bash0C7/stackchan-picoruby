# TupleSpace4Ractor — vendored from https://github.com/seki/ts4r (src/ts.rb).
#
# Original work: Copyright (c) Masatoshi SEKI (m_seki), released under MIT.
# See https://github.com/seki/ts4r/blob/main/LICENSE
#
# Reproduced here to avoid a runtime dependency on an unreleased repo. The
# implementation is unchanged except for: (a) being wrapped in the
# StackchanNotifier module namespace, (b) an added #take_nonblocking method
# used by the BLE worker's latest-wins drain loop (Ractor::Port#receive has
# no native timeout, so the non-blocking path is implemented as a separate
# command type that returns a sentinel when Rinda has no matching tuple).
#
# Pattern: Ractor owns a Rinda::TupleSpace, callers exchange tuples through
# Ractor::Port. The class itself is DRb-serializable, so one instance can be
# exposed to other processes via DRb.start_service.

require "rinda/tuplespace"

module StackchanNotifier
  class TupleSpace4Ractor
    EMPTY = :__ts4r_empty__

    class Impl
      def initialize
        @ts = Rinda::TupleSpace.new
        @read_waiter = []
        @take_waiter = []
      end

      def do_take(port, pattern)
        tuple = @ts.take(pattern, 0)
        port << tuple
        true
      rescue Rinda::RequestExpiredError
        false
      end

      def do_read(port, pattern)
        tuple = @ts.read(pattern, 0)
        port << tuple
        true
      rescue Rinda::RequestExpiredError
        false
      end

      def do_take_nb(port, pattern)
        tuple = @ts.take(pattern, 0)
        port << tuple
      rescue Rinda::RequestExpiredError
        port << EMPTY
      end

      def do_write(tuple)
        @ts.write(tuple)
        @read_waiter.delete_if { |port, pattern| do_read(port, pattern) }
        taken = false
        @take_waiter.delete_if { |port, pattern|
          break if taken
          taken = do_take(port, pattern)
        }
      end

      def main_loop
        while true
          command, tuple, port = Ractor.receive
          case command
          when :read
            @read_waiter << [port, tuple] unless do_read(port, tuple)
          when :take
            @take_waiter << [port, tuple] unless do_take(port, tuple)
          when :take_nb
            do_take_nb(port, tuple)
          when :write
            do_write(tuple)
          end
        end
      end
    end

    def initialize
      @ractor = Ractor.new { Impl.new.main_loop }
    end

    def take(pattern)
      port = Ractor::Port.new
      @ractor << [:take, pattern, port]
      port.receive
    end

    def take_nonblocking(pattern)
      port = Ractor::Port.new
      @ractor << [:take_nb, pattern, port]
      result = port.receive
      raise Rinda::RequestExpiredError if result == EMPTY
      result
    end

    def read(pattern)
      port = Ractor::Port.new
      @ractor << [:read, pattern, port]
      port.receive
    end

    def write(tuple)
      @ractor << [:write, tuple]
      tuple
    end
  end
end
