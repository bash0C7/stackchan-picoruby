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
      FRONT                     = [:hello, :command, :servo, :led, :face, :text, :torque, :read_pos, :stack_free,
                                   :selftest, :touches, :audio_begin, :audio_chunk, :audio_play, :audio_done,
                                   :servo_health]
      FRAME_KEYS                = ["F", "L", "R", "G", "B", "S", "M", "text", "YL", "YR", "PU", "T", "V",
                                   "torque", "selftest", "read"]
      ROBOT_SIDE                = { left: :right, right: :left, both: :both }

      def self.contract
        codec = Stackchan::BLE::FrameCodec
        faces = codec::FACE_INDICES.keys.map { |name| "#{codec::FACE_INDICES[name]}:#{name}" }
        sides = codec::SIDE_TO_CHAR.keys.map { |side| "#{codec::SIDE_TO_CHAR[side]}:#{ROBOT_SIDE[side]}" }
        modes = codec::MODE_TO_CHAR.keys.map { |mode| "#{codec::MODE_TO_CHAR[mode]}:#{mode}" }
        zones = Daemon::TOUCH_ZONE_NAMES.keys.map { |zone| "#{Daemon::TOUCH_ZONE_NAMES[zone]}:#{zone}" }
        [
          "faces=#{faces.sort.join(",")}",
          "sides=#{sides.sort.join(",")}",
          "modes=#{modes.sort.join(",")}",
          "keys=#{FRAME_KEYS.sort.join(",")}",
          "front=#{FRONT.map { |name| name.to_s }.sort.join(",")}",
          "zones=#{zones.sort.join(",")}",
          "subtitle=#{Stackchan::AI::FrameText::MAX_CHARS}",
        ].join(";")
      end

      def self.differences(ours, theirs)
        return "the robot offers no contract" unless theirs.is_a?(String)
        mine = ours.split(";")
        robot = theirs.split(";")
        apart = []
        mine.each { |part| apart << "controller #{part}" unless robot.include?(part) }
        robot.each { |part| apart << "robot #{part}" unless mine.include?(part) }
        apart.join("; ")
      end

      attr_reader   :last_detail_frame

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
        agree
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

      def agree
        ours = Central.contract
        answer = begin
          remote_call { remote.hello(ours) }
        rescue DeviceError => e
          @connected = false
          raise ContractMismatch, "the robot offers no contract (#{e.message})"
        end
        return if answer.is_a?(Array) && answer[0] == true
        @connected = false
        raise ContractMismatch, "contract differs: #{Central.differences(ours, answer.is_a?(Array) ? answer[1] : nil)}"
      end

      def raise_if_lost
        raise ConnectionError, "link lost" if @lost
      end

      def polls_for(ms)
        (ms + POLLING_UNIT_MS - 1) / POLLING_UNIT_MS
      end

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
