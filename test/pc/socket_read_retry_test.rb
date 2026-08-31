# SocketReadRetry is the policy behind the TCPSocket#readpartial patch in
# pc/stackchan-pico/app/drb_eintr_retry.rb. picoruby-socket's POSIX port maps
# every failing recv() to RuntimeError "read failed" with errno discarded, so
# a transient interruption cannot be told from a dead peer at the Ruby level.
# The policy is pure, so it is exercised with injected sleep/warn rather than
# a socket pair.
class SocketReadRetryTest < Picotest::Test
  def setup
    @sleeps = []
    @warns  = []
  end

  def sleep_fn
    sleeps = @sleeps
    ->(ms) { sleeps << ms }
  end

  def warn_fn
    warns = @warns
    ->(n) { warns << n }
  end

  # Fails with `message` for the first `failures` attempts, then returns :value.
  def flaky(failures, message)
    attempts = 0
    SocketReadRetry.call(sleep_fn: sleep_fn, warn_fn: warn_fn) do
      attempts += 1
      raise message if attempts <= failures
      :value
    end
  end

  def test_success_returns_the_block_value_without_sleeping
    assert_equal :value, flaky(0, SocketReadRetry::MESSAGE)
    assert_equal [], @sleeps
    assert_equal [], @warns
  end

  def test_transient_read_failure_is_retried_until_the_read_succeeds
    assert_equal :value, flaky(2, SocketReadRetry::MESSAGE)
    assert_equal [SocketReadRetry::BACKOFF_MS, SocketReadRetry::BACKOFF_MS], @sleeps
    assert_equal [1, 2], @warns
  end

  # A peer that is really gone keeps failing: the error must surface as before,
  # after a bounded number of attempts.
  def test_persistent_read_failure_is_reraised_after_the_retry_budget
    raised = nil
    begin
      flaky(99, SocketReadRetry::MESSAGE)
    rescue => e
      raised = e
    end
    assert_equal SocketReadRetry::MESSAGE, raised.message
    assert_equal SocketReadRetry::MAX_RETRIES, @sleeps.size
  end

  # Only the errno-less read failure is transient; anything else is a real
  # error and must not be replayed.
  def test_other_errors_pass_through_untouched
    raised = nil
    begin
      flaky(1, "write failed")
    rescue => e
      raised = e
    end
    assert_equal "write failed", raised.message
    assert_equal [], @sleeps
  end
end
