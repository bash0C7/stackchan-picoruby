require 'test/unit'
require 'tmpdir'
require 'stringio'
require 'fileutils'
require_relative '../acceptance/ops'

class AcceptanceOpsTest < Test::Unit::TestCase
  RAKEFILE = <<~RUBY
    task(:hang) { pid = spawn("sleep", "60"); File.write("grandchild.pid", pid); sleep 60 }
    task(:quick) { puts "finished" }
  RUBY

  def setup
    @dir = Dir.mktmpdir
    @logs = Dir.mktmpdir
    File.write(File.join(@dir, "Rakefile"), RAKEFILE)
    @ops = Acceptance::Ops.new(@logs)
  end

  def teardown
    FileUtils.rm_rf(@dir)
    FileUtils.rm_rf(@logs)
  end

  def quietly
    old = $stdout
    $stdout = StringIO.new
    yield
  ensure
    $stdout = old
  end

  def alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end

  def test_a_child_that_outlives_the_limit_is_stopped_with_its_whole_group
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    ok, out, = quietly { @ops.rake(@dir, "hang", bundle: false, limit: 1) }
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
    assert_false ok
    assert_operator elapsed, :<, 10
    assert out.end_with?("[acceptance] stopped after 1 s\n"), out.inspect
    pid = Integer(File.read(File.join(@dir, "grandchild.pid")))
    50.times { break unless alive?(pid); Kernel.sleep(0.1) }
    assert_false alive?(pid)
    assert File.read(Dir[File.join(@logs, "*.log")].first).end_with?("[acceptance] stopped after 1 s\n")
  end

  def test_a_child_that_ends_in_time_behaves_as_without_a_limit
    before = Thread.list.size
    ok, out, = quietly { @ops.rake(@dir, "quick", bundle: false, limit: 30) }
    assert_true ok
    assert_match(/finished/, out)
    assert_no_match(/stopped after/, out)
    assert_equal before, Thread.list.size
  end
end
