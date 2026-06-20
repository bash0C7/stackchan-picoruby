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
        @ble.raw_send(subtitle_frame)
        Stackchan::Voice::Streamer.new(@ble).stream(ulaw)
      end
    end

    def chat(text, speak: true)
      @ai_session ||= Stackchan::AI::Companion.new(@ble)
      reply = with_ble { @ai_session.respond(text) }
      say(reply) if speak && reply
      reply
    end

    def face(name); with_ble { @display.face(name) }; end
    def led(side:, color:, mode:); with_ble { @display.led(side: side, color: color, mode: mode) }; end
    def servo(**kwargs); with_ble { @display.servo(**kwargs) }; end
    def torque(on); with_ble { @display.torque(on) }; end
    def selftest; with_ble { @display.selftest }; end

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

    # Wrap every BLE-touching call under a single mutex + activity timestamp,
    # so the keep-alive thread and user verbs don't race on send/recv state.
    def with_ble
      @ble_mutex.synchronize do
        @last_activity = Time.now
        yield
      end
    end

    def connect_ble
      @ble = Stackchan::BLE::Client.new(device_name: @device_name, name_prefix: @name_prefix)
      @ble.connect
      @display = Stackchan::Display::Controller.new(@ble)
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
