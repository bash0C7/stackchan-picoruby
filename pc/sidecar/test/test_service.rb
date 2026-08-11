# frozen_string_literal: true

require_relative "test_helper"
require "service"

class ServiceTest < Test::Unit::TestCase
  def test_ping
    service = StackchanSidecar::Service.new(stub: true)
    assert_equal "pong", service.ping
  end

  def test_respond_stub_returns_reply_text
    service = StackchanSidecar::Service.new(stub: true)
    assert_equal "stub返答:こんにちは", service.respond("こんにちは")
  end

  def test_respond_returns_nil_when_stub_delay_exceeds_timeout
    service = StackchanSidecar::Service.new(stub: true, delay_s: 2, timeout_s: 1)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = service.respond("こんにちは")
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    assert_nil result
    assert_operator elapsed, :<, 1.9
  end

  def test_synthesize_stub_returns_bytes_sized_from_text
    service = StackchanSidecar::Service.new(stub: true)
    result = service.synthesize("abc")
    assert_equal 240, result.bytesize
  end

  def test_synthesize_returns_nil_when_stub_delay_exceeds_timeout
    service = StackchanSidecar::Service.new(stub: true, delay_s: 2, timeout_s: 1)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = service.synthesize("abc")
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    assert_nil result
    assert_operator elapsed, :<, 1.9
  end
end
