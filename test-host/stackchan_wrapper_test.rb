require 'test/unit'
require 'fileutils'
require 'open3'

# The wrapper's whole remaining job is to exec the PicoRuby CLI with the right
# argv. A fake VM records what it was handed, so this needs neither PicoRuby
# nor a running daemon.
class StackchanWrapperTest < Test::Unit::TestCase
  ROOT = File.expand_path("..", __dir__)
  DIR  = "/tmp/stackchan_wrapper_test_#{Process.pid}"

  def setup
    FileUtils.mkdir_p(DIR)
    @fake_vm = File.join(DIR, "fake_picoruby")
    File.write(@fake_vm, "#!/bin/sh\nfor a in \"$@\"; do echo \"$a\"; done\n")
    File.chmod(0o755, @fake_vm)
  end

  def teardown
    FileUtils.rm_rf(DIR)
  end

  def run_wrapper(*args)
    out, _err, status = Open3.capture3(
      { "STACKCHAN_PICORUBY" => @fake_vm, "STACKCHAN_ROOT" => ROOT, "STACKCHAN_PORT" => "8787" },
      File.join(ROOT, "pc/stackchan-pico/bin/stackchan"), *args
    )
    [out.lines.map(&:chomp), status]
  end

  def test_passes_root_port_and_the_verb_through_to_the_cli
    argv, status = run_wrapper("face", "joy")
    assert_equal ["#{ROOT}/pc/stackchan-pico/app/boot_cli.rb", ROOT, "8787", "face", "joy"], argv
    assert_true status.success?
  end

  def test_does_not_start_anything_itself
    argv, = run_wrapper("status")
    assert_equal 1, argv.count { |a| a.end_with?("boot_cli.rb") }
    refute_match(/run_with_watchdog/, argv.join(" "))
  end

  # The wrapper must not probe resident processes. The guard is
  # structural rather than a list of banned identifiers: the wrapper's contract
  # is "some assignments, then one exec", so a probe reintroduced under any new
  # name breaks this, while a name grep would wave it through.
  def test_the_wrapper_body_is_only_assignments_and_the_final_exec
    body = File.readlines(File.join(ROOT, "pc/stackchan-pico/bin/stackchan"))
               .map(&:strip)
               .reject { |line| line.empty? || line.start_with?("#") }
    assert_equal "set -eu", body.first
    assert_true body.last.start_with?("exec "),
                "the wrapper's last executable line must be the exec, got: #{body.last}"
    assert_empty body[1..-2].reject { |line| line.match?(/\A[A-Z_]+=/) },
                 "the wrapper must hold nothing but variable assignments between `set -eu` and the exec"
  end
end
