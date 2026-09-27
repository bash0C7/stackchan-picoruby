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

  def test_errors_other_than_the_errno_less_read_failure_are_not_retried
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
