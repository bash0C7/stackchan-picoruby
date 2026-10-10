module StackChan
  class Controller
    class Central
      CONNECT_TIMEOUT_MS        = 15_000
      POLLING_UNIT_MS           = 20
      ACK_TIMEOUT_MS            = 3_000
      SUBSCRIBE_SETTLE_MS       = 200
      AUDIO_DONE_TIMEOUT_MIN_MS = 30_000
      AUDIO_DONE_TIMEOUT_MAX_MS = 180_000
      AUDIO_DONE_BASE_MS        = 3_300
      SUBSCRIBE_ENABLE          = "\x01\x00"
      DRB_URI                   = "drbble://stackchan"

      attr_reader   :last_detail_frame

      def initialize(name_prefix: "StackChan", radio: nil, log_fn: nil)
        @name_prefix        = name_prefix
        @radio              = radio || Radio.new(name_prefix: name_prefix)
        @radio.on_notification = method(:handle_notification)
        @radio.on_disconnect   = method(:link_lost)
        @log_fn             = log_fn   || ->(line) { $stderr.write(line + "\n"); $stderr.flush }
        @drb_rx_handle      = nil
        @drb_tx_handle      = nil
        @drb_cccd_handle    = nil
        @drb_inbox          = []
        @drb_sent_at        = nil
        @connected          = false
        @last_detail_frame  = nil
        @lost               = false
        @parser             = StackchanProtocol::FrameParser.new
      end

      def connected?
        @connected
      end

      def lost?
        @lost
      end

      def link_lost
        reset_link
        @lost = true
      end

      def reset_link
        @connected         = false
        @drb_inbox.clear
        @drb_sent_at       = nil
        @last_detail_frame = nil
        @drb_rx_handle     = nil
        @drb_tx_handle     = nil
        @drb_cccd_handle   = nil
      end

      def connect
        reset_link
        @radio.connect_and_discover(CONNECT_TIMEOUT_MS)
        @lost = false
        unless @radio.target
          raise ConnectionError, "no #{@name_prefix} advertiser found"
        end
        if @radio.conn_handle == BLE::HCI_CON_HANDLE_INVALID
          raise ConnectionError, "GATT connect did not complete"
        end
        resolve_handles
        subscribe_tx
        raise_if_lost
        @connected = true
        self
      end

      def disconnect
        @connected = false
        self
      end

      def send
        raise ConnectionError, "not connected" unless @connected
        b = SendBuilder.new
        yield b
        b.to_frames.each { |frame| command_frame(frame) }
        self
      end

      def raw_send(frame)
        raise ConnectionError, "not connected" unless @connected
        command_frame(frame)
        self
      end

      def keepalive
        raise ConnectionError, "not connected" unless @connected
        remote_call { remote.touches }
      end

      def audio_begin(n)
        raise ConnectionError, "not connected" unless @connected
        remote_call { remote.audio_begin(n) }
      end

      def audio_chunk(bytes)
        raise ConnectionError, "not connected" unless @connected
        remote_call { remote.audio_chunk(bytes) }
      end

      def audio_play
        raise ConnectionError, "not connected" unless @connected
        remote_call { remote.audio_play }
      end

      def audio_done?
        raise ConnectionError, "not connected" unless @connected
        remote_call { remote.audio_done }
      end

      def audio_done_timeout_ms(n)
        ms = AUDIO_DONE_BASE_MS + (n * 6 / 5)
        return AUDIO_DONE_TIMEOUT_MIN_MS if ms < AUDIO_DONE_TIMEOUT_MIN_MS
        return AUDIO_DONE_TIMEOUT_MAX_MS if ms > AUDIO_DONE_TIMEOUT_MAX_MS
        ms
      end

      def drain
        while @radio.pop_and_dispatch
        end
      end

      def remote
        drain
        raise_if_lost
        raise ConnectionError, "not connected" unless @connected
        @drb_inbox.clear
        DRbBle.register(DRB_URI, self, timeout_ms: ACK_TIMEOUT_MS)
        DRb::DRbObject.new_with_uri(DRB_URI)
      end

      def call_front(msg, args)
        remote
        DRb.send_message(DRB_URI, nil, msg, args)
      end

      def send_chunk(bytes)
        raise ConnectionError, "not connected" unless @connected
        if @drb_sent_at
          wait = POLLING_UNIT_MS - (Machine.board_millis - @drb_sent_at)
          sleep_ms(wait) if wait > 0
        end
        @radio.write_value_of_characteristic_without_response(@radio.conn_handle, @drb_rx_handle, bytes)
        @drb_sent_at = Machine.board_millis
      end

      def poll
        drain
        raise_if_lost
        @drb_inbox.shift
      end

      private

      def raise_if_lost
        raise ConnectionError, "link lost" if @lost
      end

      def polls_for(ms)
        (ms + POLLING_UNIT_MS - 1) / POLLING_UNIT_MS
      end

      def resolve_handles
        services = @radio.services
        drb_rx = Nus.find_characteristic(services, Nus.drb_rx_uuid)
        drb_tx = Nus.find_characteristic(services, Nus.drb_tx_uuid)
        raise ConnectionError, "dRuby pair not found" unless drb_rx && drb_tx
        @drb_rx_handle   = drb_rx[:value_handle]
        @drb_tx_handle   = drb_tx[:value_handle]
        @drb_cccd_handle = Nus.cccd_handle(drb_tx)
        raise ConnectionError, "dRuby TX CCCD not found; discovery did not finish" unless @drb_cccd_handle
      end

      def subscribe_tx
        @radio.write_characteristic_descriptor_using_descriptor_handle(@radio.conn_handle, @drb_cccd_handle, SUBSCRIBE_ENABLE)
        settle(SUBSCRIBE_SETTLE_MS)
      end

      def settle(ms)
        polls_for(ms).times do
          drain
          sleep_ms(POLLING_UNIT_MS)
        end
      end

      def handle_notification(handle, value)
        @drb_inbox << value if handle == @drb_tx_handle
      end

      def command_frame(frame)
        @parser.reset
        hash = @parser.feed(frame)[0] || {}
        lines = remote_call { remote.command(hash) }
        @last_detail_frame = lines[1]
        raise DeviceError, "device rejected #{frame.inspect}" if lines[0] == "?\n"
      end

      def remote_call
        yield
      rescue ConnectionError, TimeoutError => e
        raise e
      rescue DRb::DRbConnError => e
        raise TimeoutError, e.message
      rescue => e
        raise DeviceError, "#{e.class}: #{e.message}"
      end
    end
  end
end
