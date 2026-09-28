require 'test/unit'
require 'open3'

class PlatformTreesTest < Test::Unit::TestCase
  ROOT = File.expand_path('..', __dir__)

  def test_r2p2_esp32_names_no_stackchan
    assert_names_no_stackchan(File.join(ROOT, 'vendor', 'R2P2-ESP32'))
  end

  def test_r2p2_darwin_names_no_stackchan
    assert_names_no_stackchan(File.join(ROOT, 'vendor', 'R2P2-darwin'))
  end

  private

  def assert_names_no_stackchan(tree)
    omit("#{tree} is not on this disk") unless File.exist?(File.join(tree, '.git'))
    out, err, status = Open3.capture3('git', '-C', tree, 'grep', '-I', '-i', '-n', 'stackchan')
    assert_include [0, 1], status.exitstatus, err
    assert_equal '', out, "#{tree} names StackChan in a tracked file"
  end
end
