require 'test/unit'

class AppRequiresTest < Test::Unit::TestCase
  ROOT = File.expand_path('..', __dir__)

  def bundled_gems
    rakefile = File.read(File.join(ROOT, 'Rakefile'))
    list = rakefile[/^DEVICE_GEM_SOURCES\s*=\s*%w\[([^\]]*)\]/, 1]
    assert_not_nil list, 'DEVICE_GEM_SOURCES = %w[...] not found in Rakefile'
    list.split
  end

  def app_requires
    File.read(File.join(ROOT, 'apps', 'robot', 'app.rb')).scan(/^\s*require\s+['"]([^'"]+)['"]/).flatten
  end

  def test_app_does_not_require_a_gem_the_rakefile_bundles_as_source
    assert_not_empty app_requires
    assert_equal [], app_requires & bundled_gems
  end
end
