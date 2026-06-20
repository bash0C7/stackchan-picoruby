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

    def initialize(device_name: DEFAULT_DEVICE_NAME, name_prefix: DEFAULT_NAME_PREFIX, socket_path: DEFAULT_SOCKET_PATH)
      @device_name   = device_name
      @name_prefix   = name_prefix
      @socket_path   = socket_path
      @ble           = nil
      @display       = nil
      @ai_session    = nil
      @event_channel = Stackchan::Event::Channel.new
      @stop_mutex    = Mutex.new
      @stop_cv       = ConditionVariable.new
      @stopped       = false
    end

    attr_reader :socket_path

    def start
      connect_ble
      start_touch_reader
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
      Stackchan::Voice::Streamer.new(@ble).stream(ulaw)
    end

    def chat(text, speak: true)
      @ai_session ||= Stackchan::AI::Companion.new(@ble)
      reply = @ai_session.respond(text)
      say(reply) if speak && reply
      reply
    end

    def face(name); @display.face(name); end
    def led(side:, color:, mode:); @display.led(side: side, color: color, mode: mode); end
    def servo(**kwargs); @display.servo(**kwargs); end
    def torque(on); @display.torque(on); end
    def selftest; @display.selftest; end

    def raw_send(frame)
      payload = frame.end_with?("\n") ? frame : "#{frame}\n"
      @ble.raw_send(payload)
    end

    # === Calibration helpers (called by CLI; pose prompts stay on the CLI). ===

    def sample_pose(samples:)
      Stackchan::BLE::Calibration.sample_pose(@ble, samples: samples)
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

    def connect_ble
      @ble = Stackchan::BLE::Client.new(device_name: @device_name, name_prefix: @name_prefix)
      @ble.connect
      @display = Stackchan::Display::Controller.new(@ble)
    end

    def start_touch_reader
      Stackchan::Event::TouchReader.new(@ble, @event_channel).start
    end

    def cleanup_stale_socket
      return unless File.exist?(@socket_path)
      raise "refusing non-socket file at #{@socket_path}" unless File.socket?(@socket_path)
      File.unlink(@socket_path)
    end
  end
end
