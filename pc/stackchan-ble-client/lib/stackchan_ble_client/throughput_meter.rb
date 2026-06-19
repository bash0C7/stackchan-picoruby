module StackchanBleClient
  # Accounts received payload bytes and detects sequence-number gaps for the
  # ble-throughput de-risking spike (Phase 4). Each payload's first byte is an
  # incrementing sequence number (mod 256); the rest is filler.
  class ThroughputMeter
    attr_reader :bytes, :gaps

    def initialize
      @bytes = 0
      @gaps = 0
      @last_seq = nil
    end

    def record(payload)
      @bytes += payload.bytesize
      seq = payload.getbyte(0)
      if @last_seq
        expected = (@last_seq + 1) & 0xFF
        @gaps += 1 if seq != expected
      end
      @last_seq = seq
    end

    def kib_per_s(seconds)
      (@bytes / 1024.0) / seconds
    end
  end
end
