module StackChan
  class Controller
    # BLE central that connects to the robot, discovers the dRuby GATT pair and calls the robot's dRuby front over it.
    class Central
      # @rbs @name_prefix: String
      # @rbs @radio: untyped
      # @rbs @log_fn: ^(String) -> void
      # @rbs @drb_rx_handle: Integer?
      # @rbs @drb_tx_handle: Integer?
      # @rbs @drb_cccd_handle: Integer?
      # @rbs @drb_inbox: Array[String]
      # @rbs @drb_sent_at: Integer?
      # @rbs @connected: bool
      # @rbs @lost: bool
      # @rbs @parser: StackchanProtocol::FrameParser

      CONNECT_TIMEOUT_MS        = 15_000
      POLLING_UNIT_MS           = 20
      ACK_TIMEOUT_MS            = 3_000
      SUBSCRIBE_SETTLE_MS       = 200
      AUDIO_DONE_TIMEOUT_MIN_MS = 30_000
      AUDIO_DONE_TIMEOUT_MAX_MS = 180_000
      AUDIO_DONE_BASE_MS        = 3_300
      SUBSCRIBE_ENABLE          = "\x01\x00"
      DRB_URI                   = "drbble://stackchan"

      attr_reader   :last_detail_frame #: String?

      # Creates a central that scans for advertisers named name_prefix; radio defaults to a Radio.
      #: (?name_prefix: String, ?radio: untyped, ?log_fn: ^(String) -> void?) -> void
      def initialize(name_prefix: "StackChan", radio: nil, log_fn: nil)
        @name_prefix        = name_prefix
        @radio              = radio || Radio.new(name_prefix: name_prefix)
        @radio.on_notification = ->(handle, value) { handle_notification(handle, value) }
        @radio.on_disconnect   = -> { link_lost }
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

      # Returns whether a link is established.
      #: () -> bool
      def connected?
        @connected
      end

      # Returns whether the link dropped since the last connect.
      #: () -> bool
      def lost?
        @lost
      end

      # Marks the link as lost and clears the link state; called when the radio reports a disconnect.
      #: () -> bool
      def link_lost
        reset_link
        @lost = true
      end

      # Clears the connected flag, the dRuby inbox, the sent timestamp, the last detail frame and the GATT handles.
      #: () -> void
      def reset_link
        @connected         = false
        @drb_inbox.clear
        @drb_sent_at       = nil
        @last_detail_frame = nil
        @drb_rx_handle     = nil
        @drb_tx_handle     = nil
        @drb_cccd_handle   = nil
      end

      # Scans, connects, discovers the dRuby pair and subscribes to its notifications; returns self.
      # Raises ConnectionError when no advertiser is found, the GATT connect fails, the pair or its CCCD is missing, or the link is lost.
      #: () -> self
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

      # Marks the central as not connected; returns self.
      #: () -> self
      def disconnect
        @connected = false
        self
      end

      # Yields a SendBuilder, then sends each of its frames to the robot; returns self.
      # Raises ConnectionError when not connected and DeviceError when the robot rejects a frame.
      #: () { (SendBuilder) -> void } -> self
      def send
        raise ConnectionError, "not connected" unless @connected
        b = SendBuilder.new
        yield b
        b.to_frames.each { |frame| command_frame(frame) }
        self
      end

      # Sends one frame string to the robot; returns self.
      # Raises ConnectionError when not connected and DeviceError when the robot rejects the frame.
      #: (String frame) -> self
      def raw_send(frame)
        raise ConnectionError, "not connected" unless @connected
        command_frame(frame)
        self
      end

      # Calls the robot's touches and returns the accumulated head-touch zones.
      # Raises ConnectionError, TimeoutError or DeviceError.
      #: () -> Array[Integer]
      def keepalive
        raise ConnectionError, "not connected" unless @connected
        remote_call { remote.touches }
      end

      # Starts an audio transfer of n bytes on the robot and returns its reply lines.
      # Raises ConnectionError, TimeoutError or DeviceError.
      #: (Integer n) -> untyped
      def audio_begin(n)
        raise ConnectionError, "not connected" unless @connected
        remote_call { remote.audio_begin(n) }
      end

      # Sends one audio chunk to the robot and returns its reply lines.
      # Raises ConnectionError, TimeoutError or DeviceError.
      #: (String bytes) -> untyped
      def audio_chunk(bytes)
        raise ConnectionError, "not connected" unless @connected
        remote_call { remote.audio_chunk(bytes) }
      end

      # Asks the robot to play the transferred audio and returns its reply lines.
      # Raises ConnectionError, TimeoutError or DeviceError.
      #: () -> untyped
      def audio_play
        raise ConnectionError, "not connected" unless @connected
        remote_call { remote.audio_play }
      end

      # Asks the robot whether playback has finished.
      # Raises ConnectionError, TimeoutError or DeviceError.
      #: () -> untyped
      def audio_done?
        raise ConnectionError, "not connected" unless @connected
        remote_call { remote.audio_done }
      end

      # Returns the playback wait limit in ms for n audio bytes, clamped between the minimum and maximum.
      #: (Integer n) -> Integer
      def audio_done_timeout_ms(n)
        ms = AUDIO_DONE_BASE_MS + (n * 6 / 5)
        return AUDIO_DONE_TIMEOUT_MIN_MS if ms < AUDIO_DONE_TIMEOUT_MIN_MS
        return AUDIO_DONE_TIMEOUT_MAX_MS if ms > AUDIO_DONE_TIMEOUT_MAX_MS
        ms
      end

      # Dispatches every pending radio event.
      #: () -> void
      def drain
        while @radio.pop_and_dispatch
        end
      end

      # Drains events, registers the dRuby transport and returns the robot's dRuby front object.
      # Raises ConnectionError when the link is lost or not connected.
      #: () -> untyped
      def remote
        drain
        raise_if_lost
        raise ConnectionError, "not connected" unless @connected
        @drb_inbox.clear
        DRbBle.register(DRB_URI, self, timeout_ms: ACK_TIMEOUT_MS)
        DRb::DRbObject.new_with_uri(DRB_URI)
      end

      # Calls the front method msg with args through DRb.send_message and returns its result.
      #: (Symbol msg, Array[untyped] args) -> untyped
      def call_front(msg, args)
        remote
        DRb.send_message(DRB_URI, nil, msg, args)
      end

      # Writes one dRuby chunk to the robot, waiting so that writes are at least one polling unit apart.
      # Raises ConnectionError when not connected.
      #: (String bytes) -> Integer
      def send_chunk(bytes)
        raise ConnectionError, "not connected" unless @connected
        if @drb_sent_at
          wait = POLLING_UNIT_MS - (Machine.board_millis - @drb_sent_at)
          sleep_ms(wait) if wait > 0
        end
        @radio.write_value_of_characteristic_without_response(@radio.conn_handle, @drb_rx_handle, bytes)
        @drb_sent_at = Machine.board_millis
      end

      # Drains events and returns the next received dRuby notification, or nil.
      # Raises ConnectionError when the link is lost.
      #: () -> String?
      def poll
        drain
        raise_if_lost
        @drb_inbox.shift
      end

      private

      # Raises ConnectionError when the link is lost.
      #: () -> void
      def raise_if_lost
        raise ConnectionError, "link lost" if @lost
      end

      # Returns the number of polling units that cover ms.
      #: (Integer ms) -> Integer
      def polls_for(ms)
        (ms + POLLING_UNIT_MS - 1) / POLLING_UNIT_MS
      end

      # Stores the dRuby RX, TX and TX CCCD handles from the discovered services.
      # Raises ConnectionError when the pair or the CCCD is missing.
      #: () -> void
      def resolve_handles
        services = @radio.services
        drb_rx = Gatt.find_characteristic(services, Gatt.drb_rx_uuid)
        drb_tx = Gatt.find_characteristic(services, Gatt.drb_tx_uuid)
        raise ConnectionError, "dRuby pair not found; #{Gatt.describe_services(services)}" unless drb_rx && drb_tx
        @drb_rx_handle   = drb_rx[:value_handle]
        @drb_tx_handle   = drb_tx[:value_handle]
        @drb_cccd_handle = Gatt.cccd_handle(drb_tx)
        raise ConnectionError, "dRuby TX CCCD not found; discovery did not finish; #{Gatt.describe_services(services)}" unless @drb_cccd_handle
      end

      # Enables notifications on the dRuby TX characteristic and waits for them to settle.
      #: () -> void
      def subscribe_tx
        @radio.write_characteristic_descriptor_using_descriptor_handle(@radio.conn_handle, @drb_cccd_handle, SUBSCRIBE_ENABLE)
        settle(SUBSCRIBE_SETTLE_MS)
      end

      # Drains radio events in polling units for ms milliseconds.
      #: (Integer ms) -> void
      def settle(ms)
        polls_for(ms).times do
          drain
          sleep_ms(POLLING_UNIT_MS)
        end
      end

      # Queues a notification value when it comes from the dRuby TX handle.
      #: (Integer handle, String value) -> void
      def handle_notification(handle, value)
        @drb_inbox << value if handle == @drb_tx_handle
      end

      # Parses the frame into a command Hash, calls the robot's command and keeps the detail line.
      # Raises DeviceError when the robot answers "?".
      #: (String frame) -> void
      def command_frame(frame)
        @parser.reset
        hash = @parser.feed(frame)[0] || {}
        lines = remote_call { remote.command(hash) }
        @last_detail_frame = lines[1]
        raise DeviceError, "device rejected #{frame.inspect}" if lines[0] == "?\n"
      end

      # Yields and returns the block's value; re-raises ConnectionError and TimeoutError, turns DRb::DRbConnError into TimeoutError and any other error into DeviceError.
      #: () { () -> untyped } -> untyped
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
