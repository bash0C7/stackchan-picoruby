require 'test/unit'
require 'prism'

class MacBootTest < Test::Unit::TestCase
  ROOT = File.expand_path('..', __dir__)
  APP = File.join(ROOT, 'pc', 'stackchan-pico', 'app')
  CONTROLLER = 'mrbgems/picoruby-stackchan-controller/mrblib'

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

  def test_boot_daemon_loads_the_controller_in_a_fixed_order_with_radio_last
    loads = load_paths(parse('boot_daemon.rb')).select { |p| p.start_with?(CONTROLLER) }
    names = loads.map { |p| File.basename(p, '.rb') }
    assert_equal %w[stackchan-controller nus central calibration daemon radio], names
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
end
