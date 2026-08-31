# The CLI attaches to launchd-managed backends; it never starts them. So a
# missing daemon must fail immediately with the command that fixes it, not
# poll for 15 seconds waiting for an auto-spawn that no longer happens.
class CliAttachTest < Picotest::Test
  def test_attach_returns_the_proxy_when_the_daemon_answers
    tries = 0
    proxy = Stackchan::CLI.attach("127.0.0.1", 8787, drb_factory: lambda { |_uri|
      tries += 1
      FakeDaemonProxy.new
    })
    assert_true proxy.is_a?(FakeDaemonProxy)
    assert_equal 1, tries
  end

  def test_attach_tries_exactly_once_when_nothing_is_listening
    tries = 0
    proxy = Stackchan::CLI.attach("127.0.0.1", 8787, drb_factory: lambda { |_uri|
      tries += 1
      raise "connection refused"
    })
    assert_nil proxy
    assert_equal 1, tries
  end

  def test_the_not_running_message_names_the_command_that_starts_the_backends
    assert_true Stackchan::CLI::NOT_RUNNING_MESSAGE.include?("rake pc:up")
  end
end
