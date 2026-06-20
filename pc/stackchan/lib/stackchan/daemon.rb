# frozen_string_literal: true

require "drb/drb"
require "drb/unix"
require_relative "ble"
require_relative "voice"
require_relative "ai"
require_relative "event"
require_relative "display"

module Stackchan
  # Long-running Mac-side process. Owns the persistent BLE link, the
  # Apple Foundation Model session (lazy), and the touch event channel,
  # and exposes verb-facing API over DRb on a Unix socket for the CLI.
  class Daemon
    DEFAULT_DEVICE_NAME = ENV["BLE_DEVICE_NAME"] || "StackChan-PicoRuby"
    DEFAULT_NAME_PREFIX = ENV["BLE_NAME_PREFIX"] || "StackChan"
    DEFAULT_SOCKET_PATH = ENV["STACKCHAN_SOCKET"] || "/tmp/stackchan-#{Process.uid}.sock"

    # Mac CoreBluetooth idle-disconnects after ~15-20s of no traffic. The
    # daemon keeps the link alive with a periodic <read:pos> (idempotent, no
    # device-visible side effect) at half the idle window.
    KEEPALIVE_INTERVAL_S = 7.0

    # Si12T 3-zone capacitive head-touch maps the raw zone index 0..2 to
     # a human-readable label that the AI companion can ground its replies on.
     # Mapping is provisional — verify against the physical sensor layout.
    TOUCH_ZONE_LABELS = {
      0 => "頭のうしろ",
      1 => "右側",
      2 => "左側",
    }.freeze
    # Note: the immediate face change on touch is intentionally on-device
    # (app/application.rb Dispatcher#react_to_touch). Putting it on the PC
    # side would mean a touch → BLE notify → DRb → BLE write round-trip
    # the human can perceive as lag. The PC only handles AI follow-up here.

    def initialize(device_name: DEFAULT_DEVICE_NAME, name_prefix: DEFAULT_NAME_PREFIX, socket_path: DEFAULT_SOCKET_PATH)
      @device_name      = device_name
      @name_prefix      = name_prefix
      @socket_path      = socket_path
      @ble              = nil
      @display          = nil
      @ai_session       = nil
      @event_channel    = Stackchan::Event::Channel.new
      @ble_mutex        = Mutex.new
      @last_activity    = Time.now
      @keepalive_thread = nil
      @stop_mutex       = Mutex.new
      @stop_cv          = ConditionVariable.new
      @stopped          = false
      @robot_state      = { last_face: nil, last_say: nil, last_heard: nil, last_action: nil, last_action_at: nil }
      @state_mutex      = Mutex.new
    end

    attr_reader :socket_path

    def start
      connect_ble
      start_touch_reader
      start_keepalive
      cleanup_stale_socket
      DRb.start_service("drbunix:#{@socket_path}", self)
      File.chmod(0o600, @socket_path) if File.exist?(@socket_path)
      $stderr.puts "[stackchand] listening on #{@socket_path}"
      self
    end

    def run
      start
      install_signal_handlers
      wait
      shutdown
    end

    def wait
      @stop_mutex.synchronize { @stop_cv.wait(@stop_mutex) until @stopped }
    end

    def stop
      @stop_mutex.synchronize do
        @stopped = true
        @stop_cv.signal
      end
    end

    def shutdown
      @keepalive_thread&.kill
      DRb.stop_service rescue nil
      @ai_session&.close
      begin
        @ble&.disconnect
      rescue StandardError
        # already disconnected / transport gone — ignore
      end
      File.unlink(@socket_path) if File.exist?(@socket_path) && File.socket?(@socket_path)
    end

    # Ruby 4.0 forbids Mutex#synchronize inside a trap; defer to a fresh thread.
    def install_signal_handlers
      %w[INT TERM].each { |sig| Signal.trap(sig) { Thread.new { stop } } }
    end

    def status
      {
        ble_connected: !@ble.nil?,
        ai_session:    !@ai_session.nil?,
        socket:        @socket_path,
        device_name:   @device_name,
        name_prefix:   @name_prefix,
      }
    end

    # === Verb-facing API (called by CLI via DRb proxy) ===

    def say(text, voice: nil, gain: nil)
      tts_opts = { voice: voice, gain: gain }.compact
      tts = Stackchan::Voice::Tts.new(**tts_opts)
      ulaw = tts.synthesize(text)
      subtitle_frame = Stackchan::AI::FrameText.build(face_index: nil, text: text)
      with_ble do
        # write_without_ack: device's dispatcher emits no ACK for standalone
        # <text:...> frames (only the chat-path <F:n,text:...> combo gets one),
        # so blocking on raw_send would time out. The frame itself is best-effort
        # subtitle decoration.
        @ble.write_without_ack(subtitle_frame)
        Stackchan::Voice::Streamer.new(@ble).stream(ulaw)
      end
      record_action(:say, text, last_say: text)
    end

    def chat(text, speak: true, touch_zone: nil)
      @ai_session ||= Stackchan::AI::Companion.new(@ble)
      ctx = robot_state_snapshot
      ctx[:touch_zone] = touch_zone if touch_zone
      ctx[:touch_zone_label] = TOUCH_ZONE_LABELS[touch_zone] if touch_zone
      reply = with_ble { @ai_session.respond(text, context: ctx) }
      record_action(:chat, text, last_heard: text)
      say(reply) if speak && reply
      reply
    end

    def face(name); with_ble { @display.face(name) }; record_action(:face, name, last_face: name); end
    def led(side:, color:, mode:); with_ble { @display.led(side: side, color: color, mode: mode) }; record_action(:led, "#{side} #{color} #{mode}"); end
    def servo(**kwargs); with_ble { @display.servo(**kwargs) }; record_action(:servo, kwargs.inspect); end
    def torque(on); with_ble { @display.torque(on) }; record_action(:torque, on ? "on" : "off"); end
    def selftest; with_ble { @display.selftest }; record_action(:selftest, nil); end

    def robot_state_snapshot
      @state_mutex.synchronize { @robot_state.dup }
    end

    def touch_zone_label(zone)
      TOUCH_ZONE_LABELS[zone]
    end

    def raw_send(frame)
      payload = frame.end_with?("\n") ? frame : "#{frame}\n"
      with_ble { @ble.raw_send(payload) }
    end

    # === Calibration helpers (called by CLI; pose prompts stay on the CLI). ===

    def sample_pose(samples:)
      with_ble { Stackchan::BLE::Calibration.sample_pose(@ble, samples: samples) }
    end

    def last_detail_frame
      @ble.last_detail_frame
    end

    # CLI calls this through DRb with a block; DRb relays each yielded event
    # back to the remote block. Loops forever until the CLI disconnects.
    def subscribe_touch
      @event_channel.each { |event| yield event }
    end

    private

    def record_action(action, detail, extras = {})
      @state_mutex.synchronize do
        @robot_state[:last_action]    = action.to_s
        @robot_state[:last_action_at] = Time.now
        @robot_state.merge!(extras)
      end
    end

    # Wrap every BLE-touching call under a single mutex + activity timestamp,
    # so the keep-alive thread and user verbs don't race on send/recv state.
    # Lazy reconnect: if the underlying CoreBluetooth link has dropped (the
    # daemon does not get a callback when it does), the first send raises
    # ConnectionError / TimeoutError — catch once, reconnect, retry the
    # caller's block. Same pattern as the old notifier worker (CLAUDE.md
    # "Keep-alive boundary").
    def with_ble
      @ble_mutex.synchronize do
        @last_activity = Time.now
        begin
          yield
        rescue Stackchan::BLE::ConnectionError, Stackchan::BLE::TimeoutError => e
          $stderr.puts "[with_ble] #{e.class}: #{e.message} — reconnecting..."
          reconnect_ble
          yield
        end
      end
    end

    def connect_ble
      @ble = Stackchan::BLE::Client.new(device_name: @device_name, name_prefix: @name_prefix)
      @ble.connect
      @display = Stackchan::Display::Controller.new(@ble)
    end

    def reconnect_ble
      begin
        @ble&.disconnect
      rescue StandardError
        # already gone
      end
      connect_ble
      start_touch_reader
      $stderr.puts "[with_ble] reconnected."
    end

    def start_touch_reader
      Stackchan::Event::TouchReader.new(@ble, @event_channel).start
    end

    # Send an idempotent <read:pos> every KEEPALIVE_INTERVAL_S of inactivity
    # to defeat Mac CoreBluetooth's ~15s idle-disconnect. read_pos returns an
    # ACK + detail frame that the existing reader_loop drains; no state change.
    def start_keepalive
      @keepalive_thread = Thread.new do
        loop do
          sleep 1.0
          next if (Time.now - @last_activity) < KEEPALIVE_INTERVAL_S
          begin
            @ble_mutex.synchronize do
              @last_activity = Time.now
              @ble.send { |s| s.read_pos }
            end
          rescue StandardError => e
            $stderr.puts "[keepalive] #{e.class}: #{e.message}"
          end
        end
      end
    end

    def cleanup_stale_socket
      return unless File.exist?(@socket_path)
      raise "refusing non-socket file at #{@socket_path}" unless File.socket?(@socket_path)
      File.unlink(@socket_path)
    end
  end
end
