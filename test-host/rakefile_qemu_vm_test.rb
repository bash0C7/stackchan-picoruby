require 'test/unit'

class RakefileQemuVmTest < Test::Unit::TestCase
  ROOT = File.expand_path('..', __dir__)

  def test_qemu_build_passes_the_picorb_vm_constant_not_a_literal
    rakefile = File.read(File.join(ROOT, 'Rakefile'))
    assert_match(/idf\.py -B build-qemu build -DPICORB_VM=#\{PICORB_VM\}/, rakefile)
  end

  def test_real_build_target_is_derived_from_the_same_r2p2_vm_task_constant
    rakefile = File.read(File.join(ROOT, 'Rakefile'))
    assert_match(/r2p2_build_cmd\("#\{R2P2_VM_TASK\}:build"\)/, rakefile)
    assert_match(/r2p2_build_cmd\("#\{R2P2_VM_TASK\}:build", 'flash', port: espport\)/, rakefile)
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
    walk = lambda do |node|
      next unless node.is_a?(Prism::Node)
      if node.is_a?(Prism::CallNode) && node.name == :task && node.block.is_a?(Prism::BlockNode)
        body = node.block.body
        src = body ? body.slice : ''
        if src.match?(/'flash'|rake flash/)
          first = body.body.first
          flashing << [node.arguments.arguments.first.slice, first&.slice]
        end
      end
      node.compact_child_nodes.each { |c| walk.(c) }
    end
    walk.(tree)
    assert_operator flashing.size, :>=, 3
    flashing.each do |name, first|
      assert_equal 'qemu_gate_then_clean!', first, "task #{name} flashes without running the QEMU gate first"
    end
  end
end
