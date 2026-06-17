require "rinda/tuplespace"
require "stackchan_ble_client"

require_relative "tuple_space4ractor"
require_relative "handlers/notify_handler"
require_relative "handlers/servo_handler"
require_relative "handlers/raw_handler"

module StackchanNotifier
  class Worker
    TUPLE_PATTERN            = [:cmd, Symbol, Hash].freeze
    SHUTDOWN_SENTINEL        = :__shutdown__
    FORCE_RECONNECT_SENTINEL = :__force_reconnect__
    DEFAULT_BACKOFF          = [1, 2, 4, 8, 30].freeze
    SHUTDOWN_TUPLE           = [:cmd, SHUTDOWN_SENTINEL,        {}].freeze
    FORCE_RECONNECT_TUPLE    = [:cmd, FORCE_RECONNECT_SENTINEL, {}].freeze

    DEFAULT_HANDLERS = {
      notify: Handlers::NotifyHandler.new,
      servo:  Handlers::ServoHandler.new,
      raw:    Handlers::RawHandler.new,
    }.freeze

    GATT_CACHE_TRAP_THRESHOLD = 3
    GATT_CACHE_TRAP_PATTERN   = /discoverServices timed out/i

    def initialize(ts:, client_factory:, logger: nil, handlers: nil,
                   backoff: DEFAULT_BACKOFF, sleep_fn: ->(s) { sleep(s) },
                   restore_sleep_fn: ->(s) { sleep(s) },
                   on_unsolicited: nil, keepalive_interval: nil,
                   keepalive_frame: "<ping:1>\n")
      @ts               = ts
      @client_factory   = client_factory
      @logger           = logger
      @handlers         = handlers || DEFAULT_HANDLERS
      @backoff          = backoff
      @sleep_fn         = sleep_fn
      @restore_sleep_fn = restore_sleep_fn
      @shutdown               = false
      @client                 = nil
      @connect_attempt        = 0
      @thread                 = nil
      @gatt_cache_trap_count  = 0
      @gatt_cache_trap_logged = false
      @shutdown_during_drain  = false
      @on_unsolicited     = on_unsolicited
      @keepalive_interval = keepalive_interval
      @keepalive_frame    = keepalive_frame
      @keepalive_thread   = nil
      @keepalive_running  = false
    end

    def start
      raise Error, "worker already started" if @thread
      @thread = Thread.new { run_loop }
      start_keepalive
      self
    end

    def shutdown(timeout: 5.0)
      return self unless @thread
      @shutdown = true
      @ts.write(SHUTDOWN_TUPLE)
      joined = @thread.join(timeout)
      log(:warn, "worker thread did not exit within #{timeout}s") unless joined
      @thread = nil
      stop_keepalive
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

        per_kind_list, was_retry = next_burst_to_deliver
        next if per_kind_list.nil? || per_kind_list.empty?
        if @shutdown_during_drain
          @shutdown_during_drain = false
          @shutdown = true
          break
        end
        if @pending_force_reconnect
          @pending_force_reconnect = false
          log(:info, "force reconnect requested; tearing down current BLE connection")
          disconnect_quietly
          @pending_retry = nil
          next
        end
        break if @shutdown

        if deliver_burst(per_kind_list)
          @pending_retry = nil
        elsif was_retry
          log(:warn, "send failed twice; dropping #{per_kind_list.inspect}")
          @pending_retry = nil
        else
          @pending_retry = per_kind_list
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
          fresh.on_unsolicited = @on_unsolicited if @on_unsolicited && fresh.respond_to?(:on_unsolicited=)
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

    def next_burst_to_deliver
      if @pending_retry
        # Peek if newer tuples have arrived; if so, drain them as fresh burst
        newer = try_take_newer
        if newer
          @pending_retry = nil
          [drain_latest_per_kind(newer), false]
        else
          [@pending_retry, true]
        end
      else
        initial = @ts.take(TUPLE_PATTERN)
        return [nil, false] if shutdown_sentinel?(initial)
        if force_reconnect_sentinel?(initial)
          @pending_force_reconnect = true
          return [[], false]
        end
        [drain_latest_per_kind(initial), false]
      end
    end

    def try_take_newer
      @ts.take_nonblocking(TUPLE_PATTERN)
    rescue Rinda::RequestExpiredError
      nil
    end

    # Collapse the queued burst into [[:kind, latest_params], ...] preserving
    # first-kind-seen order. TupleSpace4Ractor take is LIFO so the first tuple
    # returned (initial) is the newest write — "first occurrence wins" gives us
    # latest-per-kind semantics. Sentinel tuples surfaced during the drain set
    # @shutdown_during_drain / @pending_force_reconnect flags.
    def drain_latest_per_kind(initial)
      latest = {}
      order  = []
      # First-seen wins because TupleSpace is LIFO: initial and each subsequent
      # take_nonblocking return newest-first. We record on first encounter only.
      apply  = ->(t) {
        _, kind, params = t
        unless latest.key?(kind)
          order  << kind
          latest[kind] = params
        end
      }
      apply.call(initial)
      loop do
        extra = @ts.take_nonblocking(TUPLE_PATTERN)
        if shutdown_sentinel?(extra)
          @shutdown_during_drain = true
          break
        end
        if force_reconnect_sentinel?(extra)
          @pending_force_reconnect = true
          next
        end
        apply.call(extra)
      rescue Rinda::RequestExpiredError
        break
      end
      order.map { |k| [k, latest[k]] }
    end

    def deliver_burst(per_kind_list)
      per_kind_list.each do |kind, params|
        handler = @handlers[kind]
        unless handler
          log(:warn, "no handler for kind=#{kind}; dropping params=#{params.inspect}")
          next
        end
        handler.deliver(client: @client, params: params, ctx: handler_ctx)
        # DEBUG: surface last detail frame so we can see what device returned.
        if @client.respond_to?(:last_detail_frame)
          log(:info, "kind=#{kind} last_detail=#{@client.last_detail_frame.inspect}")
        end
      end
      true
    rescue StackchanBleClient::Error, IOError, SystemCallError => e
      log(:info, "send failed: #{e.class}: #{e.message}; will reconnect")
      disconnect_quietly
      false
    end

    def handler_ctx
      { ts: @ts, restore_sleep_fn: @restore_sleep_fn }
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

    def start_keepalive
      return unless @keepalive_interval
      @keepalive_running = true
      @keepalive_thread = Thread.new do
        while @keepalive_running
          sleep @keepalive_interval
          break unless @keepalive_running
          @ts.write([:cmd, :raw, { frame: @keepalive_frame }])
        end
      end
    end

    def stop_keepalive
      @keepalive_running = false
      t = @keepalive_thread
      t.join(1) if t
      @keepalive_thread = nil
    end

    def log(level, msg)
      @logger&.public_send(level, "[stackchan-notifier:worker] #{msg}")
    end
  end
end
