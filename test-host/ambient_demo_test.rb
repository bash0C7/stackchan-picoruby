require 'test/unit'
require 'fileutils'
load File.expand_path('../tools/ambient_demo.rb', __dir__)

class AmbientDemoTest < Test::Unit::TestCase
  DIR = "/tmp/ambient_demo_test_#{Process.pid}"

  def setup
    FileUtils.mkdir_p(DIR)
    @calls = File.join(DIR, "calls")
    @cli = File.join(DIR, "stackchan")
    @sleeps = []
  end

  def teardown
    FileUtils.rm_rf(DIR)
  end

  def stub_cli(*codes)
    File.write(@cli, <<~SH)
      #!/bin/sh
      echo "$*" >> #{@calls}
      n=$(wc -l < #{@calls})
      set -- #{codes.join(' ')}
      shift $((n - 1))
      exit $1
    SH
    File.chmod(0o755, @cli)
  end

  def calls
    File.readlines(@calls, chomp: true)
  end

  def wait
    out, = capture_output { @result = wait_until_connected(cli: @cli, sleep_fn: ->(s) { @sleeps << s }) }
    out
  end

  def test_connect_is_retried_after_3_s_while_the_robot_is_busy
    stub_cli(8, 8, 0)
    wait
    assert_true @result
    assert_equal ["connect"] * 3, calls
    assert_equal [3, 3], @sleeps
  end

  def test_any_other_failure_gives_up_at_once
    stub_cli(1, 0)
    wait
    assert_false @result
    assert_equal ["connect"], calls
    assert_equal [], @sleeps
  end
end
