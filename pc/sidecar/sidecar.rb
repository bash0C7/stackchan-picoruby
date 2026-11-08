root   = ARGV[0] || "."
port   = (ARGV[1] || "8788").to_i
logdir = ARGV[2] || "/tmp"
stub   = ENV["STACKCHAN_SIDECAR_STUB"] == "1"
require "drb"
load "#{root}/pc/stackchan-pico/app/drb_eintr_retry.rb"
load "#{root}/pc/sidecar/service.rb"

service = if stub
            StackchanSidecar::StubService.new
          else
            StackchanSidecar::Service.new(
              session: FoundationModel::Session.new(instructions: StackchanSidecar::PERSONA),
              say: StackchanSidecar::Say.new(logdir)
            )
          end
DRb.start_service("druby://127.0.0.1:#{port}", service)
puts "[sidecar] #{stub ? 'STUB' : 'REAL'} listening on druby://127.0.0.1:#{port}"
DRb.thread.join
