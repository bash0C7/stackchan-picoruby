Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8
require "open3"
require "tmpdir"
require "fileutils"

ROOT = File.expand_path("..", __dir__)
TEST_DIRS = [%r{\Atest/}, %r{\Atest-host/}, %r{\Aaot/test/}, %r{\Amrbgems/[^/]+/test/}].freeze
TEST_FILE = /_test\.rb\z/

def git(*args, chdir: ROOT)
  out, status = Open3.capture2e("git", *args, chdir: chdir)
  raise "git #{args.join(' ')}: #{out}" unless status.success?
  out.strip
end

def base_ref
  return git("rev-parse", ARGV[0]) if ARGV[0]
  upstream = Open3.capture2e("git", "rev-parse", "--verify", "--quiet", "@{upstream}", chdir: ROOT)
  ref = upstream[1].success? ? upstream[0].strip : "origin/main"
  git("merge-base", ref, "HEAD")
end

def test_side?(path) = TEST_DIRS.any? { |re| path.match?(re) }

def suite_of(path)
  case path
  when %r{\Atest/(device|pc)/} then $1
  when %r{\Aaot/test/} then "aot"
  when %r{\Amrbgems/picoruby-([^/]+)/test/} then $1
  end
end

def test_methods(source)
  source.scan(/^(\s*)def (test_\w+)\b.*?^\1end$/m).to_h { |_, name| [name, source[/^(\s*)def #{name}\b.*?^\1end$/m]] }
end

def touched_methods(base, path)
  now = test_methods(File.read(File.join(ROOT, path)))
  before_src, status = Open3.capture2e("git", "show", "#{base}:#{path}", chdir: ROOT)
  before = status.success? ? test_methods(before_src) : {}
  now.select { |name, body| before[name] != body }.keys
end

def results(path, out)
  text = out.gsub(/\e\[[0-9;]*m/, "")
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

base = base_ref
changed = git("diff", "--name-only", "--diff-filter=AM", base, "HEAD").lines.map(&:strip)
touched = changed.select { |p| test_side?(p) && p.match?(TEST_FILE) }
                 .to_h { |p| [p, touched_methods(base, p)] }
                 .reject { |_, names| names.empty? }
exit 0 if touched.empty?

if changed.none? { |p| !test_side?(p) }
  warn "test_must_fail_on_revert: tests changed with no code change beside them, so no code change makes them fail:"
  touched.each { |p, names| warn "  #{p}: #{names.join(', ')}" }
  exit 1
end

env = {
  "BUNDLE_GEMFILE" => File.join(ROOT, "Gemfile"),
  "PICORUBY_ROOT" => ENV["PICORUBY_ROOT"] || File.join(ROOT, "vendor", "R2P2-ESP32", "components", "picoruby-esp32", "picoruby"),
}
survivors = []
Dir.mktmpdir("revert-check") do |tmp|
  wt = File.join(tmp, "base")
  git("worktree", "add", "--detach", wt, base)
  begin
    vendor = File.join(ROOT, "vendor")
    FileUtils.ln_s(vendor, File.join(wt, "vendor")) if File.directory?(vendor) && !File.exist?(File.join(wt, "vendor"))
    changed.select { |p| test_side?(p) }.each do |p|
      FileUtils.mkdir_p(File.dirname(File.join(wt, p)))
      FileUtils.cp(File.join(ROOT, p), File.join(wt, p))
    end
    touched.each do |path, names|
      out, = Open3.capture2e(env, "bundle", "exec", *command_for(path), chdir: wt)
      seen = results(path, out)
      unrun = names.reject { |n| seen.key?(n) }
      unless unrun.empty?
        warn "test_must_fail_on_revert: #{path} did not run #{unrun.join(', ')} against #{base[0, 7]}:\n#{out.lines.last(15).join}"
        exit 1
      end
      names.each { |n| survivors << "#{path}: #{n}" if seen[n] }
    end
  ensure
    git("worktree", "remove", "--force", wt)
  end
end

exit 0 if survivors.empty?
warn "test_must_fail_on_revert: these tests pass with the code reverted to #{base[0, 7]}, so they test nothing this change does:"
survivors.each { |s| warn "  #{s}" }
exit 1
