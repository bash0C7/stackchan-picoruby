require 'test/unit'

class RakefileQemuVmTest < Test::Unit::TestCase
  ROOT = File.expand_path('..', __dir__)

  def test_qemu_build_passes_the_picorb_vm_constant_not_a_literal
    rakefile = File.read(File.join(ROOT, 'Rakefile'))
    assert_match(/idf\.py -B build-qemu \S+ build -DPICORB_VM=#\{PICORB_VM\}/, rakefile)
  end

  def test_real_build_target_is_derived_from_the_same_r2p2_vm_task_constant
    rakefile = File.read(File.join(ROOT, 'Rakefile'))
    assert_match(/r2p2_build_cmd\("#\{R2P2_VM_TASK\}:build"\)/, rakefile)
  end

  def test_picorb_vm_matches_what_r2p2_esp32_s_own_rakefile_maps_for_that_task
    rakefile = File.read(File.join(ROOT, 'Rakefile'))
    task = rakefile[/^R2P2_VM_TASK\s*=\s*'([^']+)'/, 1]
    assert task, 'expected R2P2_VM_TASK = \'...\' in Rakefile'
    vm_table = rakefile[/^R2P2_VM_BY_TASK\s*=\s*(\{[^}]*\})/, 1]
    assert vm_table, 'expected R2P2_VM_BY_TASK = { ... } in Rakefile'
    vm = eval(vm_table)[task]
    assert vm, "R2P2_VM_BY_TASK has no entry for R2P2_VM_TASK=#{task}"

    vendor_rakefile = File.read(File.join(ROOT, 'vendor', 'R2P2-ESP32', 'Rakefile'))
    assert_match(/#{Regexp.escape(task)}:\s*:#{Regexp.escape(vm)}\b/, vendor_rakefile,
                 "vendor/R2P2-ESP32/Rakefile no longer maps #{task.inspect} to #{vm.inspect} — " \
                 "the QEMU build's -DPICORB_VM would then disagree with the real build")
  end

  def test_every_task_that_flashes_firmware_passes_the_qemu_gate_first
    require 'prism'
    tree = Prism.parse_file(File.join(ROOT, 'Rakefile')).value
    flashing = []
    flash_commands = []
    walk = lambda do |node, owner|
      next unless node.is_a?(Prism::Node)
      if node.is_a?(Prism::CallNode) && node.name == :task && node.block.is_a?(Prism::BlockNode)
        name = node.arguments.arguments.first.slice
        body = node.block.body
        body = body.statements if body.is_a?(Prism::BeginNode)
        calls = body ? body.body.map(&:slice) : []
        flashing << [name, calls] if node.block.slice.include?('build_then_flash!')
        owner = name
      end
      owner = "def #{node.name}" if node.is_a?(Prism::DefNode)
      if (node.is_a?(Prism::StringNode) || node.is_a?(Prism::InterpolatedStringNode)) && node.slice.match?(/\A.flash.\z|rake flash/)
        flash_commands << owner
      end
      node.compact_child_nodes.each { |c| walk.(c, owner) }
    end
    walk.(tree, nil)
    assert_equal ['def build_then_flash!'], flash_commands.uniq, 'firmware is flashed from outside build_then_flash!'
    assert_equal %w[:build_flash :build_flash_appmrb :flash], flashing.map(&:first).sort
    flashing.each do |name, calls|
      gate = calls.index { |c| c.start_with?('qemu_gate_then_clean!') }
      flash = calls.index { |c| c.start_with?('build_then_flash!') }
      assert gate, "task #{name} flashes without running the QEMU gate"
      assert_operator gate, :<, flash, "task #{name} flashes before the QEMU gate"
    end
  end

  def test_build_then_flash_checks_the_usb_console_before_flashing
    rakefile = File.read(File.join(ROOT, 'Rakefile'))
    body = rakefile[/  def build_then_flash!\(port\)\n(.*?)\n  end\n/m, 1]
    assert body
    assert_operator body.index('flash_console_ok?'), :<, body.index('rake flash')
  end

  def test_qemu_build_keeps_its_sdkconfig_in_build_qemu_not_the_project
    rakefile = File.read(File.join(ROOT, 'Rakefile'))
    idf_lines = rakefile.lines.grep(/idf\.py -B build-qemu/)
    assert_equal 2, idf_lines.size
    idf_lines.each { |l| assert_includes l, '-DSDKCONFIG=#{QEMU_BUILD_DIR}/sdkconfig' }
    refute_match(/\bSDKCONFIG=build-qemu/, rakefile)
  end
end
