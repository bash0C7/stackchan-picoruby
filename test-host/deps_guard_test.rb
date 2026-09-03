require 'test/unit'
require 'fileutils'
require 'open3'
require 'json'

# The guard's whole job is to answer "would this still build on another disk?",
# and every way it has been wrong answered "yes" when the truth was "no". So the
# fixtures here are built to be wrong in each of those ways: a remote that only
# looks like GitHub, a pin two levels down, a submodule that is not there.
#
# Nothing reaches the network. Fake GitHub remotes are given remote-tracking refs
# by hand, which is what the guard reads; the one case that would fall through to
# a fetch is pointed at a dead proxy so it fails at once.
class DepsGuardTest < Test::Unit::TestCase
  ROOT  = File.expand_path("..", __dir__)
  GUARD = File.join(ROOT, "tools", "check_deps_pushed.sh")
  HOOK  = File.join(ROOT, "tools", "hooks", "pre_push_guard.sh")
  DIR   = "/tmp/stackchan_deps_guard_test_#{Process.pid}"

  # http.proxy pointing at a closed port turns any fetch this guard attempts into
  # an immediate refusal, so a test never waits on github.com. The identity is
  # here rather than configured per repository because `git submodule add` makes
  # clones this file never touches, and a container has no global one to fall
  # back on — which is how CI found this and a developer machine never would.
  OFFLINE = {
    "GIT_TERMINAL_PROMPT" => "0",
    "GIT_CONFIG_COUNT" => "1",
    "GIT_CONFIG_KEY_0" => "http.proxy",
    "GIT_CONFIG_VALUE_0" => "http://127.0.0.1:1",
    "GIT_AUTHOR_NAME" => "deps guard test",
    "GIT_AUTHOR_EMAIL" => "t@example.invalid",
    "GIT_COMMITTER_NAME" => "deps guard test",
    "GIT_COMMITTER_EMAIL" => "t@example.invalid",
  }.freeze

  def setup
    FileUtils.mkdir_p(DIR)
  end

  def teardown
    FileUtils.rm_rf(DIR)
  end

  # --- fixture building ---------------------------------------------------

  def git(dir, *args)
    out, err, status = Open3.capture3(OFFLINE, "git", "-C", dir, *args)
    raise "git #{args.join(' ')} in #{dir}: #{err}" unless status.success?
    out
  end

  def new_repo(path)
    FileUtils.mkdir_p(path)
    Open3.capture3(OFFLINE, "git", "init", "-q", "-b", "main", path)
    git(path, "config", "user.email", "t@example.invalid")
    git(path, "config", "user.name", "t")
    commit(path, "one")
    path
  end

  def commit(path, text)
    File.write(File.join(path, "file.txt"), "#{text}\n")
    git(path, "add", "file.txt")
    git(path, "commit", "-q", "-m", text)
    git(path, "rev-parse", "HEAD").strip
  end

  # Local paths are the only submodule source available offline, and git refuses
  # them unless asked; the guard never reads .gitmodules, only the gitlinks.
  # `submodule add` clones one level, so anything the source itself pins has to be
  # brought down after. Without that the nested directory is empty, and a git
  # command aimed at it walks up and quietly answers for the parent instead.
  def add_submodule(parent, source, path)
    git(parent, "-c", "protocol.file.allow=always", "submodule", "add", "-q", source, path)
    git(parent, "commit", "-q", "-m", "pin #{path}")
    sub = File.join(parent, path)
    git(sub, "-c", "protocol.file.allow=always", "submodule", "update", "--init", "--recursive")
    sub
  end

  # Refuse to configure a directory that is not its own repository's top level, so
  # a mistake in a fixture cannot land on the parent and look like a guard bug.
  def repo!(path)
    top = git(path, "rev-parse", "--show-toplevel").strip
    raise "#{path} is not a repository top level (git answers for #{top})" unless
      File.identical?(top, path)
    path
  end

  # Make a submodule look published: a github.com remote, and a remote-tracking
  # ref at the commit the parent pins. The guard reads the ref, so no fetch runs.
  def publish(sub, sha = nil)
    repo!(sub)
    sha ||= git(sub, "rev-parse", "HEAD").strip
    verb = git(sub, "remote").split.include?("origin") ? "set-url" : "add"
    git(sub, "remote", verb, "origin", "https://github.com/example/#{File.basename(sub)}.git")
    git(sub, "update-ref", "refs/remotes/origin/main", sha)
    sha
  end

  # A checkout of this machine, under a directory whose name contains github.com
  # exactly as ~/dev/src/github.com/... does. This is what used to pass.
  def publish_to_a_local_path_only(sub)
    repo!(sub)
    disk = File.join(DIR, "dev", "src", "github.com", "someone", File.basename(sub))
    FileUtils.mkdir_p(File.dirname(disk))
    Open3.capture3(OFFLINE, "git", "clone", "-q", "--bare", sub, disk)
    git(sub, "remote", "set-url", "origin", disk)
  end

  # A tree shaped like this repo: <root>/tools/check_deps_pushed.sh next to a
  # vendor/R2P2-ESP32 holding the pins.
  def new_tree(name)
    root = File.join(DIR, name)
    FileUtils.mkdir_p(File.join(root, "tools"))
    FileUtils.cp(GUARD, File.join(root, "tools"))
    new_repo(File.join(root, "vendor", "R2P2-ESP32"))
    root
  end

  # The guard writes UTF-8 — its messages use em dashes — while a captured string
  # is tagged with whatever the ambient locale says. A container sets none, so the
  # bytes arrive tagged US-ASCII and matching a pattern against them raises rather
  # than failing. Say what the encoding actually is.
  def utf8(text)
    text.dup.force_encoding("UTF-8")
  end

  def run_guard(root, *args)
    out, err, status = Open3.capture3(OFFLINE, File.join(root, "tools", "check_deps_pushed.sh"), *args)
    [utf8(out + err), status.exitstatus]
  end

  # --- the pins ------------------------------------------------------------

  def test_a_pin_reachable_from_github_passes
    root = new_tree("clean")
    sub = add_submodule(File.join(root, "vendor", "R2P2-ESP32"), new_repo(File.join(DIR, "src", "picoruby")), "picoruby")
    publish(sub)

    out, code = run_guard(root, "--pins-only")
    assert_equal 0, code, out
    assert_match(/picoruby ok/, out)
  end

  def test_a_remote_on_this_disk_is_not_evidence_of_publication
    root = new_tree("localonly")
    sub = add_submodule(File.join(root, "vendor", "R2P2-ESP32"), new_repo(File.join(DIR, "src", "picoruby")), "picoruby")
    publish_to_a_local_path_only(sub)

    out, code = run_guard(root, "--pins-only")
    assert_equal 2, code, out
    assert_match(/no GitHub remote/, out)
  end

  def test_a_pin_no_github_ref_reaches_fails
    root = new_tree("unpushed")
    source = new_repo(File.join(DIR, "src", "picoruby"))
    published = git(source, "rev-parse", "HEAD").strip
    commit(source, "two")
    sub = add_submodule(File.join(root, "vendor", "R2P2-ESP32"), source, "picoruby")
    publish(sub, published) # the tracking ref stops one commit short of the pin

    out, code = run_guard(root, "--pins-only")
    assert_equal 2, code, out
    assert_match(/which no GitHub ref reaches/, out)
  end

  def test_the_walk_reaches_a_pin_two_levels_down
    inner_source = new_repo(File.join(DIR, "src", "mruby"))
    outer_source = new_repo(File.join(DIR, "src", "picoruby"))
    inner = add_submodule(outer_source, inner_source, "mrbgems/picoruby-mruby/lib/mruby")
    publish_to_a_local_path_only(inner)

    root = new_tree("nested")
    sub = add_submodule(File.join(root, "vendor", "R2P2-ESP32"), outer_source, "picoruby")
    publish(sub)
    publish(File.join(sub, "mrbgems/picoruby-mruby/lib/mruby"), git(inner, "rev-parse", "HEAD").strip)
    git(File.join(sub, "mrbgems/picoruby-mruby/lib/mruby"), "remote", "set-url", "origin",
        git(inner, "remote", "get-url", "origin").strip)

    out, code = run_guard(root, "--pins-only")
    assert_equal 2, code, out
    assert_match(%r{picoruby ok}, out)
    assert_match(%r{picoruby-mruby/lib/mruby has no GitHub remote}, out)
  end

  def test_a_pin_whose_submodule_is_not_checked_out_fails_rather_than_being_skipped
    root = new_tree("uninit")
    sub = add_submodule(File.join(root, "vendor", "R2P2-ESP32"), new_repo(File.join(DIR, "src", "picoruby")), "picoruby")
    publish(sub)
    FileUtils.rm_rf(sub)
    FileUtils.mkdir_p(sub)

    out, code = run_guard(root, "--pins-only")
    assert_equal 2, code, out
    assert_match(/is not checked out/, out)
  end

  # Switching a lineage means checking the submodule out somewhere else and
  # building before the pointer is committed, which is this project's routine
  # operation and the state in which what is built here is nobody else's build.
  def test_a_submodule_sitting_off_its_pin_fails
    root = new_tree("offpin")
    sub = add_submodule(File.join(root, "vendor", "R2P2-ESP32"), new_repo(File.join(DIR, "src", "picoruby")), "picoruby")
    publish(sub)
    pinned = git(sub, "rev-parse", "HEAD").strip
    moved = commit(sub, "somewhere else")
    git(sub, "update-ref", "refs/remotes/origin/main", moved) # published, just not pinned

    out, code = run_guard(root, "--pins-only")
    assert_equal 2, code, out
    assert_match(/checked out at #{moved} but pinned at #{pinned}/, out)
  end

  # --- the gem clones the build actually compiles --------------------------

  # `conf.gem` clones into build/repos once and never pulls, so the firmware can
  # be built from a commit the build_config stopped naming. `git:` takes a URL,
  # which is what lets this run against a repository on disk.
  def write_build_config(root, body)
    firmware = File.join(root, "vendor", "R2P2-ESP32")
    config = File.join(firmware, "components", "picoruby-esp32", "build_config")
    FileUtils.mkdir_p(config)
    File.write(File.join(config, "xtensa-esp-picoruby.rb"), body)
    git(firmware, "add", "-A")
    git(firmware, "commit", "-q", "-m", "name a gem")
    publish(firmware)
  end

  def stage_gem_clone(root, source, at)
    clone = File.join(root, "vendor", "R2P2-ESP32", "components", "picoruby-esp32",
                      "picoruby", "build", "repos", "esp32-picoruby", File.basename(source))
    FileUtils.mkdir_p(File.dirname(clone))
    Open3.capture3(OFFLINE, "git", "clone", "-q", source, clone)
    git(clone, "checkout", "-q", at)
    clone
  end

  def test_a_stale_gem_clone_fails_even_though_the_ref_resolves
    root, = new_full_tree("stalegem")
    gem = new_repo(File.join(DIR, "src", "picoruby-widget"))
    old = git(gem, "rev-parse", "HEAD").strip
    commit(gem, "two")
    write_build_config(root, "conf.gem git: '#{gem}', branch: 'main'\n")
    stage_gem_clone(root, gem, old)

    out, code = run_guard(root)
    assert_equal 2, code, out
    assert_match(/build\/repos clone is at #{old}/, out)
  end

  def test_a_gem_clone_at_the_named_commit_passes
    root, = new_full_tree("freshgem")
    gem = new_repo(File.join(DIR, "src", "picoruby-widget"))
    write_build_config(root, "conf.gem git: '#{gem}', branch: 'main'\n")
    stage_gem_clone(root, gem, git(gem, "rev-parse", "HEAD").strip)

    out, code = run_guard(root)
    assert_equal 0, code, out
    assert_match(/its build\/repos clone is at that commit/, out)
  end

  # --- the vendored trees themselves --------------------------------------

  # The full run reads the build_config and expects every tree to look published,
  # so it is all set up here and left clean. An empty build_config asks nothing of
  # the network. The picoruby submodule goes in last and both trees are published
  # after it, so the only dirt is whatever the test itself makes.
  def new_full_tree(name)
    root = new_tree(name)
    new_repo(root)
    publish(root)
    firmware = File.join(root, "vendor", "R2P2-ESP32")
    config = File.join(firmware, "components", "picoruby-esp32", "build_config")
    FileUtils.mkdir_p(config)
    File.write(File.join(config, "xtensa-esp-picoruby.rb"), "# no gems\n")
    git(firmware, "add", "-A")
    git(firmware, "commit", "-q", "-m", "build_config")
    sub = add_submodule(firmware, new_repo(File.join(DIR, "src", "#{name}-picoruby")), "picoruby")
    publish(sub)
    publish(firmware)
    [root, sub]
  end

  def test_an_edit_that_lives_in_no_commit_fails
    root, sub = new_full_tree("edited")
    File.write(File.join(sub, "file.txt"), "patched here and nowhere else\n")

    out, code = run_guard(root)
    assert_equal 2, code, out
    assert_match(/picoruby has 1 uncommitted change/, out)
  end

  # picoruby-socket's mrbgem.rake `git apply`s a patch it carries onto the
  # vendored lwip, so that file is modified on every machine that has ever built.
  # Failing on it would make the guard permanently red, which is the same as off.
  def test_a_file_a_committed_patch_targets_is_not_an_edit_made_by_hand
    root, sub = new_full_tree("patched")
    FileUtils.mkdir_p(File.join(sub, "patches"))
    File.write(File.join(sub, "patches", "fix.patch"),
               "--- a/file.txt\n+++ b/file.txt\n@@ -1 +1,2 @@\n one\n+two\n")
    git(sub, "add", "-A")
    git(sub, "commit", "-q", "-m", "carry the patch")
    publish(sub)
    publish(File.join(root, "vendor", "R2P2-ESP32"), nil)
    git(File.join(root, "vendor", "R2P2-ESP32"), "add", "-A")
    git(File.join(root, "vendor", "R2P2-ESP32"), "commit", "-q", "-m", "move the pin")
    publish(File.join(root, "vendor", "R2P2-ESP32"))
    File.write(File.join(sub, "file.txt"), "one\ntwo\n") # what the patch produces

    out, code = run_guard(root)
    assert_equal 0, code, out
    assert_match(/a committed patch is applied to at build time/, out)
  end

  def test_leftovers_from_a_lineage_switch_are_named_but_do_not_fail
    root, sub = new_full_tree("strays")
    FileUtils.mkdir_p(File.join(sub, "lib", "pico-extras"))
    File.write(File.join(sub, "lib", "pico-extras", "leftover.txt"), "from another branch\n")

    out, code = run_guard(root)
    assert_equal 0, code, out
    assert_match(/picoruby has 1 untracked path/, out)
  end

  # --- where the guard looks ----------------------------------------------

  def test_from_a_worktree_it_checks_the_trees_the_main_checkout_holds
    root = new_tree("worktree-host")
    new_repo(root) # the checkout itself, so it can have a worktree
    sub = add_submodule(File.join(root, "vendor", "R2P2-ESP32"), new_repo(File.join(DIR, "src", "picoruby")), "picoruby")
    publish_to_a_local_path_only(sub)

    tree = File.join(DIR, "worktrees", "branch")
    git(root, "worktree", "add", "-q", "-b", "side", tree)
    FileUtils.mkdir_p(File.join(tree, "tools"))
    FileUtils.cp(GUARD, File.join(tree, "tools"))

    # vendor/ is gitignored, so the worktree has none: answering from itself
    # would report nothing to check, which is the false pass.
    assert_false Dir.exist?(File.join(tree, "vendor", "R2P2-ESP32"))
    out, code = run_guard(tree, "--pins-only")
    assert_equal 2, code, out
    assert_match(/no GitHub remote/, out)
  end

  # --- the hook that runs it ----------------------------------------------

  # A stub in place of the guard, recording that it was reached and answering
  # however the caller asks. `ran` is a file rather than output, because the hook
  # swallows the guard's stdout and only speaks on stderr when it refuses.
  def run_hook(command, verdict: 0)
    dir = File.join(DIR, "hook")
    FileUtils.mkdir_p(File.join(dir, "tools", "hooks"))
    FileUtils.cp(HOOK, File.join(dir, "tools", "hooks"))
    ran = File.join(dir, "ran")
    FileUtils.rm_f(ran)
    stub = File.join(dir, "tools", "check_deps_pushed.sh")
    File.write(stub, "#!/bin/sh\ntouch #{ran}\necho 'the pin is unpublished'\nexit #{verdict}\n")
    File.chmod(0o755, stub)

    payload = { tool_name: "Bash", tool_input: { command: command, description: "d" } }
    _, err, status = Open3.capture3(File.join(dir, "tools", "hooks", "pre_push_guard.sh"),
                                    stdin_data: JSON.generate(payload))
    { ran: File.exist?(ran), stderr: utf8(err), code: status.exitstatus }
  end

  def hook_decision(command)
    run_hook(command)[:ran]
  end

  def test_the_hook_fires_on_every_shape_of_push_this_repo_actually_uses
    assert_true hook_decision("git push --dry-run origin main")
    assert_true hook_decision("git -C vendor/R2P2-ESP32 push origin HEAD:c-primitives-verified")
    assert_true hook_decision("/opt/homebrew/bin/git push origin main")
    assert_true hook_decision("cd vendor/R2P2-ESP32 && git push")
  end

  def test_the_hook_stays_out_of_the_way_otherwise
    assert_false hook_decision("ls tools/")
    assert_false hook_decision("git status --short")
    assert_false hook_decision("git log --oneline -3")
    # The repo's own path spells github.com and its files are named push.
    assert_false hook_decision("cp /Users/x/dev/src/github.com/y/w tools/hooks/pre_push_guard.sh")
  end

  def test_the_push_that_publishes_a_pin_can_say_so_and_get_through
    assert_false hook_decision("STACKCHAN_DEPS_GUARD=off git -C x push origin HEAD:published")
  end

  # A blocked tool call shows the hook's stderr and nothing else, so a refusal
  # that says nothing there tells whoever hit it only that something went wrong.
  def test_a_refusal_says_on_stderr_which_dependency_is_missing
    result = run_hook("git push origin main", verdict: 2)
    assert_equal 2, result[:code]
    assert_match(/the pin is unpublished/, result[:stderr])
  end

  def test_a_clean_answer_lets_the_push_through_silently
    result = run_hook("git push origin main", verdict: 0)
    assert_true result[:ran]
    assert_equal 0, result[:code]
    assert_equal "", result[:stderr]
  end
end
