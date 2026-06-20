# frozen_string_literal: true

require "shellwords"

module Stackchan
  module REPL
    PROMPT = "stackchan> "
    HELP = <<~TXT
      Type any stackchan verb at the prompt:
        face <neutral|smile|joy|surprised|sad|angry|closed>
        led <left|right|both> <color> <solid|blink|breathing|off>
        servo --yaw-left N --pitch-up N --time MS
        torque on | torque off
        selftest
        say "..." [--gain 0.1]
        chat "..." [--no-speak]
        status
      Touch events stream inline as [touch] zone=N.
      Special: h | help (this), q | quit (exit).
    TXT

    # In-session operator console: a single shell hosts both verb input
    # and touch-event output. The background thread subscribes to the
    # daemon's touch channel; the foreground reads lines and delegates
    # to the existing CLI dispatcher so every verb behaves identically.
    class Runner
      DISALLOWED_IN_REPL = %w[repl tui stop touch].freeze

      def initialize(cli, daemon, stdin: $stdin, stdout: $stdout)
        @cli = cli
        @daemon = daemon
        @stdin = stdin
        @stdout = stdout
        @stdout_mutex = Mutex.new
        @touch_thread = nil
      end

      def run
        sync_puts(HELP)
        start_touch_listener
        loop do
          @stdout.print PROMPT
          @stdout.flush
          line = @stdin.gets
          break if line.nil?
          line = line.strip
          next if line.empty?
          break if %w[q quit exit].include?(line)
          if %w[h help ?].include?(line)
            sync_puts(HELP)
            next
          end
          dispatch_line(line)
        end
      ensure
        @touch_thread&.kill
      end

      private

      def dispatch_line(line)
        argv = Shellwords.split(line)
        verb = argv.shift
        if DISALLOWED_IN_REPL.include?(verb)
          sync_puts("  '#{verb}' is not available inside repl (would deadlock or recurse).")
          return
        end
        unless Stackchan::CLI::VERBS.include?(verb)
          sync_puts("  unknown verb: #{verb} (h for help)")
          return
        end
        @cli.dispatch(verb, argv)
      rescue ArgumentError => e
        sync_puts("  argument error: #{e.message}")
      rescue StandardError => e
        sync_puts("  #{e.class}: #{e.message}")
      end

      def start_touch_listener
        @touch_thread = Thread.new do
          begin
            @daemon.subscribe_touch do |event|
              sync_puts("\n[touch] zone=#{event[:zone]}")
              @stdout.print PROMPT
              @stdout.flush
            end
          rescue StandardError
            # daemon disconnected — the foreground loop will notice on the next gets
          end
        end
      end

      def sync_puts(msg)
        @stdout_mutex.synchronize { @stdout.puts(msg) }
      end
    end
  end
end
