require "rinda/tuplespace"
require "stackchan_ble_client"

require_relative "tuple_space4ractor"

module StackchanNotifier
  class Worker
    TUPLE_PATTERN     = [:notify, Symbol, Integer, Symbol, Symbol].freeze
    SHUTDOWN_SENTINEL = :__shutdown__
    DEFAULT_BACKOFF   = [1, 2, 4, 8, 30].freeze
    SHUTDOWN_TUPLE    = [:notify, SHUTDOWN_SENTINEL, 0, SHUTDOWN_SENTINEL, SHUTDOWN_SENTINEL].freeze

    def initialize(ts:, client_factory:, logger: nil, backoff: DEFAULT_BACKOFF, sleep_fn: ->(s) { sleep(s) })
      @ts             = ts
      @client_factory = client_factory
      @logger         = logger
      @backoff        = backoff
      @sleep_fn       = sleep_fn
      @shutdown       = false
      @client         = nil
      @connect_attempt = 0
      @thread         = nil
    end

    def start
      raise Error, "worker already started" if @thread
      @thread = Thread.new { run_loop }
      self
    end

    def shutdown(timeout: 5.0)
      return self unless @thread
      @shutdown = true
      # Unblock the blocking take so the loop notices @shutdown.
      @ts.write(SHUTDOWN_TUPLE)
      joined = @thread.join(timeout)
      log(:warn, "worker thread did not exit within #{timeout}s") unless joined
      @thread = nil
      self
    end

    def thread
      @thread
    end

    private

    def run_loop
      @pending_retry = nil
      until @shutdown
        ensure_connected
        break if @shutdown

        tuple, was_retry = next_tuple_to_deliver
        next if shutdown_sentinel?(tuple)
        break if @shutdown

        if deliver(tuple)
          @pending_retry = nil
        elsif was_retry
          log(:warn, "send failed twice; dropping #{tuple.inspect}")
          @pending_retry = nil
        else
          @pending_retry = tuple
        end
      end
      disconnect_quietly
    end

    def ensure_connected
      while !@shutdown && @client.nil?
        begin
          fresh = @client_factory.call
          fresh.connect
          @client = fresh
          @connect_attempt = 0
          log(:info, "BLE connected")
        rescue StackchanBleClient::Error, IOError, SystemCallError => e
          @connect_attempt += 1
          delay = @backoff[[@connect_attempt - 1, @backoff.size - 1].min]
          log(:warn, "connect failed (attempt=#{@connect_attempt}): #{e.class}: #{e.message}; sleeping #{delay}s")
          @sleep_fn.call(delay)
        end
      end
    end

    def next_tuple_to_deliver
      if @pending_retry
        newer = try_take_newer
        if newer
          @pending_retry = nil
          [drain_latest(newer), false]
        else
          [@pending_retry, true]
        end
      else
        initial = @ts.take(TUPLE_PATTERN)
        [drain_latest(initial), false]
      end
    end

    def try_take_newer
      @ts.take_nonblocking(TUPLE_PATTERN)
    rescue Rinda::RequestExpiredError
      nil
    end

    # Rinda::TupleSpace#take returns the most-recently-written matching tuple
    # first (LIFO), so `initial` (passed in from the blocking take above) is
    # already the latest. This loop just garbage-collects the older queued
    # tuples so the bag does not grow unbounded.
    def drain_latest(initial)
      loop do
        extra = @ts.take_nonblocking(TUPLE_PATTERN)
        if shutdown_sentinel?(extra)
          @shutdown_during_drain = true
          break
        end
      rescue Rinda::RequestExpiredError
        break
      end
      initial
    end

    def deliver(tuple)
      _, face, hsb, mode, side = tuple
      @client.send do |s|
        s.face(face)
        s.led(:hsb, hsb, side: side, mode: mode)
      end
      true
    rescue StackchanBleClient::Error, IOError, SystemCallError => e
      log(:warn, "send failed: #{e.class}: #{e.message}; will reconnect")
      disconnect_quietly
      false
    end

    def shutdown_sentinel?(tuple)
      tuple && tuple[1] == SHUTDOWN_SENTINEL
    end

    def disconnect_quietly
      @client&.disconnect
    rescue StackchanBleClient::Error, IOError, SystemCallError => e
      log(:debug, "disconnect (best-effort) raised: #{e.class}: #{e.message}")
    ensure
      @client = nil
    end

    def log(level, msg)
      @logger&.public_send(level, "[stackchan-notifier:worker] #{msg}")
    end
  end
end
