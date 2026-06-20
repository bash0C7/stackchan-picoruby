require_relative "test_helper"
require "stackchan/ble"

class ThroughputMeterTest < Test::Unit::TestCase
  def test_counts_bytes
    m = Stackchan::BLE::ThroughputMeter.new
    m.record("\x00abc")  # 4 bytes, seq 0
    m.record("\x01defg") # 5 bytes, seq 1
    assert_equal 9, m.bytes
    assert_equal 0, m.gaps
  end

  def test_detects_sequence_gap
    m = Stackchan::BLE::ThroughputMeter.new
    m.record("\x00x")
    m.record("\x02x")   # skipped seq 1
    assert_equal 1, m.gaps
  end

  def test_seq_wraps_at_256
    m = Stackchan::BLE::ThroughputMeter.new
    m.record("\xFFx")
    m.record("\x00x")   # 255 -> 0 wrap is contiguous
    assert_equal 0, m.gaps
  end

  def test_kib_per_s
    m = Stackchan::BLE::ThroughputMeter.new
    m.record("\x00" + ("x" * 1023)) # 1024 bytes
    assert_in_delta 1.0, m.kib_per_s(1.0), 0.001
  end
end
