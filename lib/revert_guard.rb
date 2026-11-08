require "open3"
require "tmpdir"
require "fileutils"

class RevertGuard
  TEST_DIRS = [%r{\Atest/}, %r{\Atest-host/}, %r{\Aaot/test/}, %r{\Amrbgems/[^/]+/test/}].freeze
  TEST_FILE = /_test\.rb\z/
  PROJECT_ROOT = File.expand_path("..", __dir__)

  def initialize(root:, base: nil, err: $stderr)
    @root = root
    @base = base
    @err = err
  end

  def run
    base = base_ref
    changed = git("diff", "--name-only", "--diff-filter=AM", base, "HEAD").lines.map(&:strip)
    touched = changed.select { |p| test_side?(p) && p.match?(TEST_FILE) }
                     .to_h { |p| [p, touched_methods(base, p)] }
                     .reject { |_, names| names.empty? }
    return 0 if touched.empty?

    if changed.none? { |p| !test_side?(p) }
      say "tests changed with no code change beside them, so no code change makes them fail:"
      touched.each { |p, names| @err.puts "  #{p}: #{names.join(', ')}" }
      return 1
    end

    survivors = []
    Dir.mktmpdir("revert-check") do |tmp|
      wt = File.join(tmp, "base")
      git("worktree", "add", "--detach", wt, base)
      begin
        vendor = File.join(@root, "vendor")
        FileUtils.ln_s(vendor, File.join(wt, "vendor")) if File.directory?(vendor) && !File.exist?(File.join(wt, "vendor"))
        changed.select { |p| test_side?(p) }.each do |p|
          FileUtils.mkdir_p(File.dirname(File.join(wt, p)))
          FileUtils.cp(File.join(@root, p), File.join(wt, p))
        end
        touched.each do |path, names|
          out, = Open3.capture2e(env, "bundle", "exec", *command_for(path), chdir: wt)
          seen = results(path, out)
          unrun = names.reject { |n| seen.key?(n) }
          next if seen.empty? && path.start_with?("test-host/") && out.match?(/cannot load such file/)
          unless unrun.empty?
            say "#{path} did not run #{unrun.join(', ')} against #{base[0, 7]}:\n#{out.lines.last(15).join}"
            return 1
          end
          names.each { |n| survivors << "#{path}: #{n}" if seen[n] }
        end
      ensure
        git("worktree", "remove", "--force", wt)
      end
    end

    return 0 if survivors.empty?
    say "these tests pass with the code reverted to #{base[0, 7]}, so they test nothing this change does:"
    survivors.each { |s| @err.puts "  #{s}" }
    1
  end

  private

  def say(msg)
    @err.puts "guard:revert: #{msg}"
  end

  def env
    { "BUNDLE_GEMFILE" => File.join(PROJECT_ROOT, "Gemfile"),
      "PICORUBY_ROOT" => ENV["PICORUBY_ROOT"] || File.join(PROJECT_ROOT, "vendor", "R2P2-ESP32", "components", "picoruby-esp32", "picoruby") }
  end

  def git(*args, chdir: @root)
    out, status = Open3.capture2e("git", *args, chdir: chdir)
    raise "git #{args.join(' ')}: #{out}" unless status.success?
    out.strip
  end

  def base_ref
    return git("rev-parse", @base) if @base
    upstream = Open3.capture2e("git", "rev-parse", "--verify", "--quiet", "@{upstream}", chdir: @root)
    ref = upstream[1].success? ? upstream[0].strip : "origin/main"
    git("merge-base", ref, "HEAD")
  end

  def test_side?(path) = TEST_DIRS.any? { |re| path.match?(re) }

  def suite_of(path)
    case path
    when %r{\Atest/(device|pc|sidecar|tools)/} then $1
    when %r{\Aaot/test/} then "aot"
    when %r{\Amrbgems/picoruby-([^/]+)/test/} then $1
    end
  end

  def test_methods(source)
    source.scan(/^(\s*)def (test_\w+)\b.*?^\1end$/m).to_h { |_, name| [name, source[/^(\s*)def #{name}\b.*?^\1end$/m]] }
  end

  def touched_methods(base, path)
    now = test_methods(File.read(File.join(@root, path), encoding: "UTF-8"))
    before_src, status = Open3.capture2e("git", "show", "#{base}:#{path}", chdir: @root)
    before = status.success? ? test_methods(before_src.force_encoding("UTF-8")) : {}
    now.select { |name, body| before[name] != body }.keys
  end

  def results(path, out)
    text = out.dup.force_encoding("UTF-8").scrub.gsub(/\e\[[0-9;]*m/, "")
    if path.start_with?("test-host/")
      text.scan(/^\s+(test_\w+):\s*([.FEONP])/).to_h { |name, mark| [name, mark == "."] }
    else
      text.scan(/^\s+\w+#(test_\w+) (.*)$/).to_h { |name, marks| [name, marks.strip.match?(/\A\.*\z/)] }
    end
  end

  def command_for(path)
    if path.start_with?("test-host/")
      ["ruby", "-Ilib", "-Itest-host", path, "--verbose=verbose"]
    else
      ["rake", "picotest:run", "SUITE=#{suite_of(path)}", "FILTER=#{File.basename(path, '.rb')}"]
    end
  end
end
