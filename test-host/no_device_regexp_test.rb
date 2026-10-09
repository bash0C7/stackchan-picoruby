require 'test/unit'
require 'prism'

class NoDeviceRegexpTest < Test::Unit::TestCase
  ROOT = File.expand_path('..', __dir__)

  def test_no_on_device_ruby_source_uses_regexp
    files = device_files
    assert_not_empty files

    offenders = files.each_with_object([]) do |path, acc|
      hits = find_regexp(Prism.parse(File.read(path)).value)
      acc << [path, hits] unless hits.empty?
    end

    assert_equal [], offenders,
      "regex literal or Regexp reference found in on-device source (firmware has no Regexp): #{offenders.inspect}"
  end

  private

  def rakefile
    @rakefile ||= File.read(File.join(ROOT, 'Rakefile'))
  end

  def device_gem_source_files
    list = rakefile[/^DEVICE_GEM_DIRS\s*=\s*%w\[([^\]]*)\]/, 1]
    assert_not_nil list, 'DEVICE_GEM_DIRS = %w[...] not found in Rakefile'
    list.split.flat_map { |g| Dir[File.join(ROOT, "mrbgems/picoruby-#{g}/mrblib/**/*.rb")] }
  end

  def repo_local_r2p2_gem_dirs
    config = File.read(File.join(ROOT, 'build_config', 'esp32-stackchan.rb'))
    dirs = config.scan(%r{conf\.gem gemdir: File\.expand_path\('\.\./(mrbgems/[^']+)', __dir__\)}).flatten
    assert_include dirs, 'mrbgems/picoruby-stackchan-protocol',
      "build_config/esp32-stackchan.rb no longer names the protocol gem; update this test's device file list"
    dirs.map { |d| File.join(ROOT, d) }
  end

  def r2p2_gem_dir_mrblib_files
    repo_local_r2p2_gem_dirs.flat_map { |dir| Dir[File.join(dir, 'mrblib/**/*.rb')] }
  end

  def device_files
    (device_gem_source_files + r2p2_gem_dir_mrblib_files + [File.join(ROOT, 'apps/robot/app.rb')]).sort.uniq
  end

  def find_regexp(node, acc = [])
    return acc unless node.respond_to?(:child_nodes)

    case node
    when Prism::RegularExpressionNode, Prism::InterpolatedRegularExpressionNode
      acc << node.slice
    when Prism::ConstantReadNode, Prism::ConstantPathNode
      acc << node.slice if node.name == :Regexp
    end

    node.child_nodes.compact.each { |child| find_regexp(child, acc) }
    acc
  end
end
