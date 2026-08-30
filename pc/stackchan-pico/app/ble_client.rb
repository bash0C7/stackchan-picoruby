# Real picoruby-ble central client for the StackChan NUS. Replaces FakeBleClient
# in deployment. Three parts:
#
#   NusResolver      — PURE logic (UUID -> handle resolution, frame classification).
#                      Host-testable without a radio (verified 10/10).
#   StackchanRadio   — the actual `BLE` subclass. Only overrides what BLE requires
#                      (advertising_report_callback, packet_callback) plus the
#                      connect-and-discover driver.
#   StackchanCentral — the drop-in FakeBleClient replacement the daemon holds.
#                      Wraps a StackchanRadio and exposes the verb-facing API
#                      (connect/connected?/send/raw_send/write_without_ack/...).
#
# Implemented against a sibling project's WORKING picoruby-ble central for this
# same darwin-port gem: R2P2-iOS's Stack-chan example
# (github.com/bash0C7/R2P2-iOS, examples/virtual-peripheral's sibling design —
# see build/ios-stackchan-app*/.../Stackchan.app/app.rb for the built artifact).
# That reference resolved the two load-bearing questions this file previously
# left as NotImplementedError:
#
# 1. StackchanRadio must NOT define its own `connect`. `BLE#connect(report)`
#    (ble_central.rb) is the inherited "GAP-connect to this advertiser" method;
#    `advertising_report_callback` calls it BY NAME. A same-named zero-arg
#    override on the subclass (the old design) would shadow it and break that
#    call with ArgumentError the moment a matching advertiser was seen. The
#    daemon-facing "connect everything" entry point lives on the WRAPPER
#    (StackchanCentral#connect) instead, under a different receiver.
#
# 2. `BLE#scan(timeout_ms:, stop_state: :TC_IDLE)` (-> `start`) blocks
#    (cooperative `sleep_ms` inside `start`'s loop) until the state machine
#    reaches `stop_state` or the timeout elapses. Connecting to the first
#    matching advertiser from INSIDE `advertising_report_callback` (by calling
#    the inherited `connect(report)`) keeps the still-running outer `scan`
#    loop driving the rest of GATT discovery (services -> characteristics ->
#    descriptors) until `@state == :TC_IDLE` — one `scan` call is the whole
#    connect+discover sequence, no manual state polling needed.
#
# LOAD-BEARING GOTCHA (found by reading the darwin port's own Swift source,
# not by trial and error): `BLE#start` calls `hci_power_control(HCI_POWER_ON)`
# on ENTRY every time, and the darwin port re-emits a fresh
# BTSTACK_EVENT_STATE(WORKING) packet on every such call (PicoBLECentral.swift
# `powerOn()`, deliberately, per its own comment). `ble_central.rb`'s decoder
# processes that packet whenever `@state` is `:TC_OFF` OR `:TC_IDLE` — and
# `:TC_IDLE` is exactly the state we are in once connected+discovered. So
# calling `scan`/`start` a second time after the initial connect would
# immediately call `start_scan` again, which the Swift side implements as
# `pbleSharedFifo.flush()` — dropping every pending packet, INCLUDING an
# in-flight ACK/notification this code is waiting on. Conclusion: after the
# initial `scan`, this code never calls `scan`/`start`/`connect` again. All
# further draining (ACK-wait, touch notifications) uses the lower-level
# `pop_packet` + `packet_callback` primitives directly (the same primitives
# `picoruby-ble-uart`/`-hid` call bare, without `start`), which never touch
# `hci_power_control` and therefore never re-trigger the rescan/flush chain.
# `hci_power_control(OFF)` (in `scan`'s own `ensure`) is confirmed benign on
# darwin: CoreBluetooth callbacks (writes, `didUpdateValueFor` notifications)
# are not gated by that flag (`PicoBLECentral.swift#powerOff`'s own comment:
# "Do NOT drop an established connection").
#
# GATT_EVENT_NOTIFICATION (0xA7): the darwin port's Swift backend DOES
# synthesize this for every unsolicited update on a subscribed characteristic
# (`PicoBLEPackets.swift#pbleNotification`, called from
# `PicoBLECentral.swift#didUpdateValueFor` — contradicting the port README's
# blanket "central path does not synthesize ... 0xA7/0xA8" note, which is
# stale). `ble_central.rb`'s `packet_callback` still leaves the 0xA7 branch
# empty (`# TODO`), so `StackchanRadio#packet_callback` overrides it (calling
# `super` first to preserve the base state machine) to decode and route it.
#
# CCCD subscribe: `write_characteristic_descriptor_using_descriptor_handle`
# targeting a characteristic's CCCD handle maps to CoreBluetooth's
# `setNotifyValue` (`PicoBLECentral.swift#writeDescriptor`) — a non-zero first
# byte enables notifications, matching the `"\x01\x00"` convention used
# elsewhere in this codebase (e.g. the PBLE-TEST live-BLE spike).

module NusResolver
  # NOTE: bare `module_function` is a no-op on PicoRuby; the explicit
  # `module_function :sym, ...` form at the end of the module is required.

  # 16-byte big-endian UUID for a Nordic UART Service member.
  #   suffix 0x0001 = service, 0x0002 = RX (write), 0x0003 = TX (notify)
  def nus_uuid(suffix_hi, suffix_lo)
    [0x6e, 0x40, suffix_hi, suffix_lo,
     0xb5, 0xa3, 0xf3, 0x93, 0xe0, 0xa9,
     0xe5, 0x0e, 0x24, 0xdc, 0xca, 0x9e].pack("C*")
  end

  def rx_uuid; nus_uuid(0x00, 0x02); end
  def tx_uuid; nus_uuid(0x00, 0x03); end

  # CCCD (Client Characteristic Configuration Descriptor) UUID 0x2902, as the
  # 16-byte form the central stores after reverse_128.
  def cccd_uuid
    [0x00, 0x00, 0x29, 0x02, 0x00, 0x00, 0x10, 0x00,
     0x80, 0x00, 0x00, 0x80, 0x5f, 0x9b, 0x34, 0xfb].pack("C*")
  end

  # Find a characteristic Hash (the shape ble_central.rb builds) by uuid128
  # across all discovered services. Returns nil if absent.
  def find_characteristic(services, uuid128)
    si = 0
    while si < services.size
      chs = services[si][:characteristics]
      ci = 0
      while ci < chs.size
        return chs[ci] if chs[ci][:uuid128] == uuid128
        ci += 1
      end
      si += 1
    end
    nil
  end

  # The CCCD descriptor handle of a characteristic, or nil.
  def cccd_handle(characteristic)
    return nil unless characteristic
    ds = characteristic[:descriptors]
    i = 0
    while i < ds.size
      return ds[i][:handle] if ds[i][:uuid128] == cccd_uuid
      i += 1
    end
    nil
  end

  # Classify an inbound notified frame the way the daemon's reader needs:
  #   :touch  — unsolicited <touch:N> (route to touch handler)
  #   :ack    — bare "." / "?" ACK byte
  #   :detail — a servo/read detail frame (<..._actual:..> / <yaw_raw:..>)
  #   :other  — anything else (e.g. <rx:...> throughput summary)
  def classify(frame)
    return :touch if Stackchan::BLE::FrameCodec.touch_event?(frame)
    head = frame[0, 1]
    return :ack if head == Stackchan::BLE::FrameCodec::ACK_OK || head == Stackchan::BLE::FrameCodec::ACK_ERROR
    return :detail if frame.include?("_actual:") || frame.include?("_raw:")
    :other
  end

  module_function :nus_uuid, :rx_uuid, :tx_uuid, :cccd_uuid,
                  :find_characteristic, :cccd_handle, :classify
end

# `defined?(BLE)` guards both radio-touching classes so this file also loads on
# a VM without the ble gem (host testing of NusResolver in isolation).
if Object.const_defined?(:BLE)
  # The actual `BLE` subclass. Deliberately minimal: only the two callbacks BLE
  # requires, plus the connect-and-discover driver. See the file-level comment
  # for why this class must never define its own `connect`.
  class StackchanRadio < BLE
    attr_reader :target

    def initialize(name_prefix:)
      @name_prefix    = name_prefix
      @target         = nil
      @on_notification = nil
      super(:central)
    end

    attr_accessor :on_notification

    # Not exposed by ble_central.rb's own attr_reader list.
    def conn_handle
      @conn_handle
    end

    # One poll step. `_event_popped` FIRST: on the darwin port that is the
    # only place a packet moves from the Swift FIFO into @event_queue, so a
    # poll that skipped it while the queue was empty would wait for the 1 s
    # heartbeat before seeing anything. Then a non-blocking pop + dispatch.
    def pop_and_dispatch
      _event_popped
      event = @event_queue.pop(timeout_ms: 0)
      return nil unless event
      packet_callback(event) if event.is_a?(String)
      event
    end

    # Called by the base class while @state == :TC_W4_SCAN_RESULT (you must
    # override this — the base body is empty). Connecting to the FIRST
    # matching advertiser from inside this callback, via the INHERITED
    # `connect(report)`, is what lets discovery finish inside the caller's
    # single `scan` call (see file-level comment, point 2).
    def advertising_report_callback(report)
      return if @target
      return unless report.name_include?(@name_prefix)
      @target = report
      connect(report)
    end

    # Extend the shared decoder with GATT_EVENT_NOTIFICATION (0xA7); see the
    # file-level comment for why the darwin backend emits it but
    # ble_central.rb leaves it undecoded.
    def packet_callback(event_packet)
      super
      return unless event_packet.getbyte(0) == GATT_EVENT_NOTIFICATION
      handle = BLE::Utils.little_endian_to_int16(event_packet.byteslice(4, 1))
      len    = BLE::Utils.little_endian_to_int16(event_packet.byteslice(6, 1))
      cb = @on_notification
      cb.call(handle, event_packet.byteslice(8, len)) if cb
    end

    # Drive scan -> connect -> full GATT discovery in one blocking (but
    # cooperative — `sleep_ms` inside `start`'s loop yields to other Tasks)
    # call. Returns once @state == :TC_IDLE or timeout_ms elapses; check
    # `target`/`state` afterward to see which.
    def connect_and_discover(timeout_ms)
      @target = nil
      scan(timeout_ms: timeout_ms, stop_state: :TC_IDLE)
    end
  end

  # Verb-facing wrapper. Same interface as FakeBleClient: connect / connected? /
  # send{|builder| } / raw_send / write_without_ack / max_write_chunk /
  # last_detail_frame / on_unsolicited= / disconnect.
  class StackchanCentral
    CONNECT_TIMEOUT_MS = 15_000   # scan-wait + connect + full GATT discovery
    # This class's own cooperative-wait cadence, no longer sourced from
    # BLE::POLLING_UNIT_MS (dropped when the gem moved to Task::Queue).
    POLLING_UNIT_MS    = 100
    ACK_TIMEOUT_TICKS  = 30       # x POLLING_UNIT_MS(100ms) = ~3s
    SUBSCRIBE_ENABLE   = "\x01\x00"

    attr_accessor :on_unsolicited
    attr_reader   :last_detail_frame

    def initialize(name_prefix: "StackChan")
      @name_prefix        = name_prefix
      @radio              = StackchanRadio.new(name_prefix: name_prefix)
      @radio.on_notification = method(:handle_notification)
      @rx_handle          = nil
      @tx_handle          = nil
      @cccd_handle        = nil
      @inbox              = []
      @connected          = false
      @on_unsolicited     = nil
      @last_detail_frame  = nil
    end

    def connected?
      @connected
    end

    def connect
      @radio.connect_and_discover(CONNECT_TIMEOUT_MS)
      unless @radio.target
        raise Stackchan::BLE::ConnectionError, "no #{@name_prefix} advertiser found"
      end
      # NOT @radio.state == :TC_IDLE: ble_central.rb's `scan` unconditionally
      # resets @state to :TC_OFF via its own trailing `reset_state` call
      # ("In order to be able to scan again") once `start` returns, whether
      # discovery succeeded or not — so checking @state here is always false,
      # even after a fully successful connect+discover. @conn_handle is set
      # once (HCI_SUBEVENT_LE_CONNECTION_COMPLETE) and untouched by
      # `reset_state`, so it is the correct success signal (same check as
      # R2P2-darwin's reference StackchanCentral#connected?).
      unless @radio.conn_handle != BLE::HCI_CON_HANDLE_INVALID
        raise Stackchan::BLE::ConnectionError, "GATT connect did not complete"
      end
      resolve_handles
      subscribe_tx
      @connected = true
      self
    end

    def disconnect
      @connected = false
      self
    end

    # Real client reads a negotiated MTU from CoreBluetooth on the CRuby side
    # (rb-corebluetooth-mac); the darwin-ble central gem exposes no equivalent
    # query, so this mirrors FakeBleClient's fixed value — the same
    # conservative default (macOS write-without-response cap) used everywhere
    # else in this codebase (Voice::Streamer::DEFAULT_CHUNK etc.).
    def max_write_chunk
      180
    end

    def send
      raise Stackchan::BLE::ConnectionError, "not connected" unless @connected
      b = Stackchan::BLE::SendBuilder.new
      yield b
      b.to_frames.each { |frame| write_and_await_ack(frame) }
      self
    end

    def raw_send(frame)
      raise Stackchan::BLE::ConnectionError, "not connected" unless @connected
      write_and_await_ack(frame)
      self
    end

    def write_without_ack(payload)
      raise Stackchan::BLE::ConnectionError, "not connected" unless @connected
      write_rx(payload)
      self
    end

    AUDIO_DONE_TIMEOUT_MIN_TICKS = 300   # x POLLING_UNIT_MS(100ms) = ~30s floor (previous fixed value; short-clip behavior unchanged)
    AUDIO_DONE_TIMEOUT_MAX_TICKS = 1800  # x POLLING_UNIT_MS(100ms) = ~180s hard cap -- never an unbounded wait
    AUDIO_DONE_BASE_MS = 3300            # measured intercept, see audio_done_timeout_ticks

    # Wait for the device's <A:done> half-duplex-audio completion notification
    # (app/application.rb's StackChanApp#consume_rx writes this only after
    # AudioReceiver#consume fully returns -- i.e. after both the T-ms pre-play
    # delay AND the actual mu-law decode + I2S playback + silence-tail write
    # have all finished). Actively waiting for the notification -- rather than
    # sleeping a fixed/estimated duration -- stays correct regardless of the
    # formula's accuracy; the tick budget below is only a safety net in case
    # the notification is ever lost, but it must scale with clip size (a
    # fixed ~30s net was observed timing out on longer clips while the device
    # stayed healthy) and still stay bounded.
    def audio_done_timeout_ticks(n)
      # Derived from a real-hardware sweep (2026-08-11, 15KB-61KB range):
      # ~0.95ms/byte + ~3.3s base, essentially linear (mid-range prediction
      # off actual by <1%). Rounded up to 1.2ms/byte for margin. This
      # contradicts the sub-linear 5.6KB/33KB spot-check in e29b0341's commit
      # message -- that measurement predates this sweep and is superseded by
      # it, not reconciled with it.
      ms = AUDIO_DONE_BASE_MS + (n * 6 / 5)
      ticks = ms / POLLING_UNIT_MS
      return AUDIO_DONE_TIMEOUT_MIN_TICKS if ticks < AUDIO_DONE_TIMEOUT_MIN_TICKS
      return AUDIO_DONE_TIMEOUT_MAX_TICKS if ticks > AUDIO_DONE_TIMEOUT_MAX_TICKS
      ticks
    end

    def await_audio_done(n)
      raise Stackchan::BLE::ConnectionError, "not connected" unless @connected
      @inbox.clear
      cap = audio_done_timeout_ticks(n)
      i = 0
      while i < cap
        @radio.pop_and_dispatch
        if (idx = @inbox.index { |f| f.start_with?("<A:done>") })
          @inbox.delete_at(idx)
          return self
        end
        sleep_ms(POLLING_UNIT_MS)
        i += 1
      end
      raise Stackchan::BLE::TimeoutError, "<A:done> timeout"
    end

    private

    def resolve_handles
      services = @radio.services
      rx = NusResolver.find_characteristic(services, NusResolver.rx_uuid)
      tx = NusResolver.find_characteristic(services, NusResolver.tx_uuid)
      raise Stackchan::BLE::ConnectionError, "NUS RX not found" unless rx
      raise Stackchan::BLE::ConnectionError, "NUS TX not found" unless tx
      @rx_handle   = rx[:value_handle]
      @tx_handle   = tx[:value_handle]
      @cccd_handle = NusResolver.cccd_handle(tx)
    end

    # Enable notifications on TX so ACK/detail/touch frames route through
    # StackchanRadio#packet_callback -> handle_notification. A couple of
    # settle ticks give CoreBluetooth's setNotifyValue time to land before the
    # first real write goes out — ble_central.rb's decode table has no
    # central-side "subscribe complete" event to wait on instead.
    def subscribe_tx
      return unless @cccd_handle
      @radio.write_characteristic_descriptor_using_descriptor_handle(
        @radio.conn_handle, @cccd_handle, SUBSCRIBE_ENABLE)
      pump(2)
    end

    def handle_notification(handle, value)
      return unless handle == @tx_handle
      case NusResolver.classify(value)
      when :touch
        cb = @on_unsolicited
        cb.call(value) if cb
      else
        @inbox << value
      end
    end

    def write_rx(payload)
      @radio.write_value_of_characteristic_without_response(@radio.conn_handle, @rx_handle, payload)
    end

    def write_and_await_ack(frame)
      @last_detail_frame = nil
      @inbox.clear
      write_rx(frame)
      first = await_inbox
      raise Stackchan::BLE::TimeoutError, "ACK timeout for #{frame.inspect}" unless first
      status = NusResolver.classify(first)
      if status == :ack
        if servo_or_read?(frame)
          @last_detail_frame = await_inbox
          # Diagnostic only (no behavior change): an intermittent, unexplained
          # real-hardware defect (2026-07-04, see completion-plan memory
          # "servo-family real-hardware reliability when torque is OFF") saw
          # this second await return a bare ACK/ERROR byte instead of a real
          # <..._actual:...> detail frame. Root cause not established (could
          # not reproduce in 20+ follow-up attempts) -- log the raw bytes if
          # it recurs so the next investigation has evidence instead of
          # starting from zero again.
          if @last_detail_frame && NusResolver.classify(@last_detail_frame) == :ack
            $stderr.write("[ble_client] anomaly: detail-frame slot got an ACK-like byte #{@last_detail_frame.inspect} for #{frame.inspect}\n")
            $stderr.flush
          end
        end
        return if first[0, 1] == Stackchan::BLE::FrameCodec::ACK_OK
        raise Stackchan::BLE::DeviceError, "device rejected #{frame.inspect}"
      else
        # detail-only response (no separate ACK byte)
        @last_detail_frame = first
      end
    end

    def await_inbox
      pump(ACK_TIMEOUT_TICKS)
      @inbox.shift
    end

    # Cooperative wait: drain the BLE event queue directly (pop_and_dispatch)
    # rather than BLE#start/#scan — see the file-level comment for why calling
    # start/scan again after the initial connect would flush any in-flight
    # packet we are waiting on.
    def pump(ticks)
      i = 0
      while @inbox.empty? && i < ticks
        @radio.pop_and_dispatch
        sleep_ms(POLLING_UNIT_MS)
        i += 1
      end
    end

    # No alternation regex on PicoRuby — String includes.
    def servo_or_read?(frame)
      frame.include?("YL:") || frame.include?("YR:") || frame.include?("PU:") || frame.start_with?("<read:")
    end
  end
end
