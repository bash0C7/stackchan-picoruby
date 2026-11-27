require "test/unit"
require "json"
require "open3"

class DeviceGuardTest < Test::Unit::TestCase
  ROOT = File.expand_path("..", __dir__)
  HOOK = File.join(ROOT, "tools", "hooks", "device_guard.sh")

  def run_guard(command, agent_id: nil, tool_name: "Bash")
    payload = { tool_name: tool_name, tool_input: { command: command, description: "d" } }
    payload[:agent_id] = agent_id if agent_id
    out, err, status = Open3.capture3(HOOK, stdin_data: JSON.generate(payload))
    { stdout: out, stderr: err, code: status.exitstatus }
  end

  def test_blocks_raw_cat_on_usbmodem_everywhere
    main_res = run_guard("cat /dev/cu.usbmodem14101")
    sub_res = run_guard("cat /dev/tty.usbmodem14101", agent_id: "sub_1")
    assert_equal 2, main_res[:code]
    assert_match(/capture-with-pty/, main_res[:stderr])
    assert_equal 2, sub_res[:code]
  end

  def test_blocks_direct_idf_flash_and_esptool_erase_everywhere
    %w[
      idf.py\ flash
      idf.py\ erase-flash
      esptool.py\ write_flash\ 0x0\ app.bin
      esptool\ erase_region\ 0x410000\ 0x10000
    ].each do |cmd|
      res = run_guard(cmd, agent_id: "sub_1")
      assert_equal 2, res[:code], cmd
      assert_match(/QEMU boot gate/, res[:stderr])
    end
  end

  def test_blocks_rm_rf_on_build_repos_everywhere
    res = run_guard("rm -rf vendor/R2P2-ESP32/build/repos/picoruby", agent_id: "sub_1")
    assert_equal 2, res[:code]
    assert_match(/shallow clones/, res[:stderr])
  end

  def test_blocks_mutating_r2p2_tasks_from_main_context
    [
      "bundle exec rake r2p2:build_flash",
      "bundle exec rake r2p2:full_rebuild SRC=apps/robot/app.rb",
      "bundle exec rake r2p2:upload_appmrb SRC=apps/robot/app.rb",
      "bundle exec rake r2p2:wipe_storage",
      "bundle exec rake r2p2:reset",
      "FACE=joy bundle exec rake r2p2:ble_control_smoke",
      "bundle exec rake r2p2:monitor",
      "bundle exec rake r2p2:boards && bundle exec rake r2p2:reset"
    ].each do |cmd|
      res = run_guard(cmd)
      assert_equal 2, res[:code], cmd
      assert_not_empty res[:stderr]
    end
  end

  def test_allows_mutating_r2p2_tasks_from_subagent_or_forked_skill
    [
      "bundle exec rake r2p2:build_flash",
      "bundle exec rake r2p2:upload_appmrb SRC=apps/robot/app.rb",
      "bundle exec rake r2p2:reset",
      "bundle exec rake acceptance:deploy",
      "bundle exec rake acceptance:app"
    ].each do |cmd|
      res = run_guard(cmd, agent_id: "agent_fork_1")
      assert_equal 0, res[:code], "#{cmd}: #{res[:stderr]}"
      assert_equal "", res[:stderr]
    end
  end

  def test_allows_readonly_r2p2_and_pty_capture_from_main_context
    [
      "bundle exec rake r2p2:boards",
      "bundle exec rake r2p2:flash_identity",
      "bundle exec rake r2p2:qemu_check",
      "bin/capture-with-pty 25 /tmp/boot.log bundle exec rake r2p2:monitor"
    ].each do |cmd|
      res = run_guard(cmd)
      assert_equal 0, res[:code], "#{cmd}: #{res[:stderr]}"
      assert_equal "", res[:stderr]
    end
  end

  def test_blocks_acceptance_deploy_and_app_from_main_context
    %w[acceptance:deploy acceptance:app].each do |task|
      res = run_guard("bundle exec rake #{task}")
      assert_equal 2, res[:code], task
      assert_match(/stackchan-device-acceptance/, res[:stderr])
    end
  end

  def test_allows_non_executing_mentions_and_other_tools
    [
      "grep r2p2:build_flash Rakefile",
      "rg r2p2:upload_appmrb .claude/",
      "git commit -m \"guard rake r2p2:flash and cat /dev/cu.usbmodem0\"",
      "bundle exec rake test",
      "bundle exec rake acceptance:check"
    ].each do |cmd|
      res = run_guard(cmd)
      assert_equal 0, res[:code], "#{cmd}: #{res[:stderr]}"
    end

    non_bash = run_guard("bundle exec rake r2p2:build_flash", tool_name: "Read")
    assert_equal 0, non_bash[:code]
  end

  def test_allows_explicit_override
    res = run_guard("STACKCHAN_DEVICE_GUARD=off bundle exec rake r2p2:reset")
    assert_equal 0, res[:code]
  end

  def test_blocks_when_description_field_is_absent
    payload = { tool_name: "Bash", tool_input: { command: "bundle exec rake r2p2:reset" } }
    _, err, status = Open3.capture3(HOOK, stdin_data: JSON.generate(payload))
    assert_equal 2, status.exitstatus
    assert_match(/r2p2:reset/, err)
  end
end
