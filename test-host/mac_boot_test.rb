require 'test/unit'
require 'prism'

class MacBootTest < Test::Unit::TestCase
  ROOT = File.expand_path('..', __dir__)
  APP = File.join(ROOT, 'pc', 'stackchan-pico', 'app')
  CONTROLLER = 'mrbgems/picoruby-stackchan-controller/mrblib'
  MAC_APP = 'apps/mac/app.rb'

  def controller_files
    Dir.chdir(File.join(ROOT, CONTROLLER)) do
      ['stackchan-controller.rb', *Dir['stackchan-controller/*.rb'].sort].map { |f| "#{CONTROLLER}/#{f}" }
    end
  end

  def load_paths(node)
    found = []
    walk = lambda do |n|
      next unless n
      if n.is_a?(Prism::CallNode) && n.name == :load && n.receiver.nil?
        arg = n.arguments.arguments.first
        assert_kind_of Prism::InterpolatedStringNode, arg
        head, *rest = arg.parts
        assert_equal 'root', head.statements.body.first.slice
        found << rest.map(&:unescaped).join.delete_prefix('/')
      end
      n.compact_child_nodes.each { |c| walk.call(c) }
    end
    walk.call(node)
    found
  end

  def parse(name)
    Prism.parse_file(File.join(APP, name)).value
  end

  def fake_branch
    parse('boot_daemon.rb').statements.body.find do |n|
      n.is_a?(Prism::IfNode) && n.predicate.slice == 'name_prefix == "fake"'
    end
  end

  def test_boot_daemon_loads_every_controller_file_but_the_cli_exactly_once
    loads = load_paths(parse('boot_daemon.rb')).select { |p| p.start_with?(CONTROLLER) }
    expected = controller_files.reject { |p| p.end_with?('/cli.rb') }
    assert_equal expected.sort, loads.sort
    assert_equal loads.uniq, loads
  end

  def test_radio_loads_only_on_the_non_fake_branch
    branch = fake_branch
    assert_not_nil branch
    radio = "#{CONTROLLER}/stackchan-controller/radio.rb"
    assert_equal [], load_paths(branch.statements).select { |p| p == radio }
    assert_equal [radio], load_paths(branch.compact_child_nodes.grep(Prism::ElseNode).first).select { |p| p == radio }
  end

  def test_boot_cli_loads_only_the_cli_and_calibration_from_the_controller
    loads = load_paths(parse('boot_cli.rb')).select { |p| p.start_with?(CONTROLLER) }
    assert_equal %W[#{CONTROLLER}/stackchan-controller/calibration.rb #{CONTROLLER}/stackchan-controller/cli.rb], loads
  end

  def test_every_loaded_path_exists
    %w[boot_daemon.rb boot_cli.rb].each do |boot|
      load_paths(parse(boot)).each do |path|
        assert File.exist?(File.join(ROOT, path)), "#{boot} loads missing #{path}"
      end
    end
  end
  def serve_call
    found = []
    walk = lambda do |n|
      next unless n
      found << n if n.is_a?(Prism::CallNode) && n.name == :serve && n.receiver&.slice == 'App'
      n.compact_child_nodes.each { |c| walk.call(c) }
    end
    walk.call(parse('boot_daemon.rb'))
    found
  end

  def nodes_of(node, *types)
    found = []
    walk = lambda do |n|
      next unless n
      found << n if types.any? { |t| n.is_a?(t) }
      n.compact_child_nodes.each { |c| walk.call(c) }
    end
    walk.call(node)
    found
  end

  def test_boot_daemon_loads_the_mac_app_once_after_every_controller_file
    loads = load_paths(parse('boot_daemon.rb'))
    assert_equal 1, loads.count(MAC_APP)
    last_gem = loads.rindex { |p| p.start_with?(CONTROLLER) }
    assert_operator loads.index(MAC_APP), :>, last_gem
  end

  def test_boot_daemon_serves_the_app_with_the_sidecar_from_the_fourth_argument
    calls = serve_call
    assert_equal 1, calls.size
    keys = calls.first.arguments.arguments.first.elements.map { |e| e.key.unescaped }
    assert_equal %w[port host name_prefix sidecar_uri], keys
    body = parse('boot_daemon.rb').statements.body
    assert_operator body.index { |n| n.slice.include?(calls.first.slice) },
                    :>, body.index { |n| load_paths(n).include?(MAC_APP) }
    assert_match(/ARGV\[3\]/, File.read(File.join(APP, 'boot_daemon.rb')))
  end

  def test_the_mac_app_is_exactly_one_app_assignment_of_a_controller
    tree = Prism.parse_file(File.join(ROOT, MAC_APP))
    assert_empty tree.errors
    body = tree.value.statements.body
    assert_equal 1, body.size
    node = body.first
    assert_kind_of Prism::ConstantWriteNode, node
    assert_equal :App, node.name
    assert_kind_of Prism::CallNode, node.value
    assert_equal 'StackChan', node.value.receiver.slice
    assert_equal :controller, node.value.name
    assert_kind_of Prism::BlockNode, node.value.block
  end

  def test_the_mac_app_has_no_require_global_or_instance_variable_or_class
    tree = Prism.parse_file(File.join(ROOT, MAC_APP)).value
    requires = nodes_of(tree, Prism::CallNode).select { |n| %i[require require_relative load].include?(n.name) && n.receiver.nil? }
    assert_empty requires.map(&:slice)
    globals = nodes_of(tree, Prism::GlobalVariableReadNode, Prism::GlobalVariableWriteNode,
                       Prism::GlobalVariableOperatorWriteNode, Prism::GlobalVariableOrWriteNode,
                       Prism::GlobalVariableAndWriteNode, Prism::GlobalVariableTargetNode)
    assert_empty globals.map(&:slice)
    ivars = nodes_of(tree, Prism::InstanceVariableReadNode, Prism::InstanceVariableWriteNode,
                     Prism::InstanceVariableOperatorWriteNode, Prism::InstanceVariableOrWriteNode,
                     Prism::InstanceVariableAndWriteNode, Prism::InstanceVariableTargetNode)
    assert_empty ivars.map(&:slice)
    defs = nodes_of(tree, Prism::ClassNode, Prism::ModuleNode, Prism::DefNode, Prism::SingletonClassNode)
    assert_empty defs.map(&:slice)
    consts = nodes_of(tree, Prism::ConstantWriteNode, Prism::ConstantPathWriteNode)
    assert_equal ['App'], consts.map { |n| n.respond_to?(:name) ? n.name.to_s : n.slice }
  end
end
