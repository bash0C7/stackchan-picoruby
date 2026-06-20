# frozen_string_literal: true

module Stackchan
  module TUI
    HELP = <<~TXT
      commands:
        yl N        yaw toward StackChan's LEFT  (0..100)
        yr N        yaw toward StackChan's RIGHT (0..100)
        pu N        pitch UP                     (0..100)
        fwd         forward / level (yaw 0 + pitch 0)
        ton | toff  torque on / off
        face NAME   set face (neutral, joy, closed, ...)
        t MS        move duration ms for subsequent moves (default 800)
        h | help    this help
        q | quit    exit
    TXT

    class Runner
      def initialize(daemon, stdin: $stdin, stdout: $stdout)
        @daemon = daemon
        @stdin = stdin
        @stdout = stdout
      end

      def run
        @stdout.puts HELP
        move_ms = 800
        loop do
          @stdout.print "\nstackchan> "
          @stdout.flush
          line = @stdin.gets
          break if line.nil? # EOF
          cmd, arg = line.strip.split(/\s+/, 2)
          next if cmd.nil? || cmd.empty?

          begin
            case cmd
            when "yl"   then move(yaw_left: magnitude(arg), time_ms: move_ms)
            when "yr"   then move(yaw_right: magnitude(arg), time_ms: move_ms)
            when "pu"   then move(pitch_up: magnitude(arg), time_ms: move_ms)
            when "fwd"  then move(yaw_left: 0, pitch_up: 0, time_ms: move_ms)
            when "ton"  then @daemon.torque(true)
            when "toff" then @daemon.torque(false)
            when "face"
              raise ArgumentError, "face requires a name" if arg.nil? || arg.empty?
              @daemon.face(arg)
            when "t"
              move_ms = Integer(arg, 10)
              @stdout.puts "  move duration = #{move_ms} ms"
            when "h", "help"
              @stdout.puts HELP
            when "q", "quit", "exit"
              break
            else
              @stdout.puts "  unknown: #{cmd} (h for help)"
            end
          rescue ArgumentError => e
            @stdout.puts "  error: #{e.message}"
          end
        end
      end

      private

      def move(**kw)
        detail = @daemon.servo(**kw)
        @stdout.puts "  detail: #{detail.inspect}" if detail
      end

      def magnitude(arg)
        n = Integer(arg, 10)
        raise ArgumentError, "magnitude must be 0..100, got #{n}" unless n.between?(0, 100)
        n
      end
    end
  end
end
