require "rinda/tuplespace"
require "stackchan_ble_client"

require_relative "tuple_space4ractor"

module StackchanNotifier
  class Worker
    TUPLE_PATTERN            = [:notify, Symbol, Integer, Symbol, Integer, Symbol, nil].freeze
    SHUTDOWN_SENTINEL        = :__shutdown__
    FORCE_RECONNECT_SENTINEL = :__force_reconnect__
    DEFAULT_BACKOFF          = [1, 2, 4, 8, 30].freeze
    SHUTDOWN_TUPLE           = [:notify, SHUTDOWN_SENTINEL,        0, :solid, 0, :solid, nil].freeze
    FORCE_RECONNECT_TUPLE    = [:notify, FORCE_RECONNECT_SENTINEL, 0, :solid, 0, :solid, nil].freeze
    RESTORE_TUPLE            = [:notify, :neutral,                 0, :solid, 0, :solid, nil].freeze

    # GATT cache trap detection. When macOS CoreBluetooth's GATT cache is
    # stale for our peripheral, every reconnect attempt fails the same way
    # (`discoverServices timed out after 5000ms`). Detect N such consecutive
    # failures and surface a single actionable ERROR — the daemon cannot
    # programmatically clear the cache (no public API as of macOS 14), so
    # the user has to power-cycle the StackChan to recover.
    GATT_CACHE_TRAP_THRESHOLD = 3
    GATT_CACHE_TRAP_PATTERN   = /discoverServices timed out/i

    def initialize(ts:, client_factory:, logger: nil, backoff: DEFAULT_BACKOFF, sleep_fn: ->(s) { sleep(s) }, restore_sleep_fn: ->(s) { sleep(s) })
      @ts               = ts
      @client_factory   = client_factory
      @logger           = logger
      @backoff          = backoff
      @sleep_fn         = sleep_fn
      @restore_sleep_fn = restore_sleep_fn
      @shutdown               = false
      @client                 = nil
      @connect_attempt        = 0
      @thread                 = nil
      @restore_thread         = nil
      @gatt_cache_trap_count  = 0
      @gatt_cache_trap_logged = false
    end

    def start
      raise Error, "worker already started" if @thread
      @thread = Thread.new { run_loop }
      self
    end

    def shutdown(timeout: 5.0)
      return self unless @thread
      cancel_pending_restore
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

    def force_reconnect
      @ts.write(FORCE_RECONNECT_TUPLE)
    end

    private

    def run_loop
      @pending_retry = nil
      @pending_force_reconnect = false
      until @shutdown
        ensure_connected
        break if @shutdown

        tuple, was_retry = next_tuple_to_deliver
        next if shutdown_sentinel?(tuple)
        if @pending_force_reconnect || force_reconnect_sentinel?(tuple)
          @pending_force_reconnect = false
          log(:info, "force reconnect requested; tearing down current BLE connection")
          disconnect_quietly
          @pending_retry = nil
          next
        end
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
          @connect_attempt        = 0
          @gatt_cache_trap_count  = 0
          @gatt_cache_trap_logged = false
          log(:info, "BLE connected")
        rescue StackchanBleClient::Error, IOError, SystemCallError => e
          @connect_attempt += 1
          track_gatt_cache_trap(e)
          delay = @backoff[[@connect_attempt - 1, @backoff.size - 1].min]
          log(:warn, "connect failed (attempt=#{@connect_attempt}): #{e.class}: #{e.message}; sleeping #{delay}s")
          maybe_log_gatt_cache_trap
          @sleep_fn.call(delay)
        end
      end
    end

    def track_gatt_cache_trap(error)
      if GATT_CACHE_TRAP_PATTERN.match?(error.message.to_s)
        @gatt_cache_trap_count += 1
      else
        @gatt_cache_trap_count  = 0
        @gatt_cache_trap_logged = false
      end
    end

    def maybe_log_gatt_cache_trap
      return if @gatt_cache_trap_logged
      return if @gatt_cache_trap_count < GATT_CACHE_TRAP_THRESHOLD
      log(:error,
          "BLE GATT discovery stuck (#{@gatt_cache_trap_count} consecutive `discoverServices` timeouts). " \
          "macOS CoreBluetooth has cached a stale GATT for this device and there is no programmatic " \
          "API to clear it — please power-cycle the StackChan (unplug/replug USB-C or hard-reset the " \
          "M5Stack). The daemon will keep retrying in the background; once the device reboots the next " \
          "scan should succeed.")
      @gatt_cache_trap_logged = true
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
        @pending_force_reconnect = true if force_reconnect_sentinel?(extra)
      rescue Rinda::RequestExpiredError
        break
      end
      initial
    end

    def deliver(tuple)
      cancel_pending_restore
      _, face, left_color, left_mode, right_color, right_mode, duration = tuple
      @client.send do |s|
        s.face(face)
        s.led(:hsb, left_color,  side: :left,  mode: left_mode)
        s.led(:hsb, right_color, side: :right, mode: right_mode)
      end
      schedule_restore(duration) if duration && duration > 0
      true
    rescue StackchanBleClient::Error, IOError, SystemCallError => e
      # Task 1 retry slot will re-deliver the same tuple after ensure_connected
      # reconnects, so a single send failure is recoverable noise — INFO. The
      # WARN escalation lives in run_loop's "send failed twice; dropping" path.
      log(:info, "send failed: #{e.class}: #{e.message}; will reconnect")
      disconnect_quietly
      false
    end

    def schedule_restore(seconds)
      @restore_thread = Thread.new(seconds) do |secs|
        @restore_sleep_fn.call(secs)
        @ts.write(RESTORE_TUPLE)
      end
    end

    def cancel_pending_restore
      @restore_thread&.kill
      @restore_thread = nil
    end

    def shutdown_sentinel?(tuple)
      tuple && tuple[1] == SHUTDOWN_SENTINEL
    end

    def force_reconnect_sentinel?(tuple)
      tuple && tuple[1] == FORCE_RECONNECT_SENTINEL
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
