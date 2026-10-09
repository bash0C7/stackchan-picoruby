require 'test/unit'
require 'yaml'

class R2p2RefTest < Test::Unit::TestCase
  ROOT = File.expand_path('..', __dir__)

  def test_the_rakefile_clones_the_r2p2_esp32_branch_the_acceptance_firmware_pins
    rakefile = File.read(File.join(ROOT, 'Rakefile'))
    ref = rakefile[/^R2P2_ESP32_REF\s*=\s*ENV\["R2P2_ESP32_REF"\]\s*\|\|\s*"([^"]+)"/, 1]
    assert_not_nil ref, 'R2P2_ESP32_REF default not found in Rakefile'

    lock = File.read(File.join(ROOT, 'acceptance', 'lock.yml'))
    firmware = lock[/^firmware:\n(.*?)(?=^\S|\z)/m, 1]
    assert_not_nil firmware, 'firmware not found in acceptance/lock.yml'
    branch = firmware[/^  R2P2-ESP32:\s*\h{40}\s*#\s*(\S+)/, 1]
    assert_not_nil branch, 'firmware R2P2-ESP32 pin has no branch comment'

    assert_equal branch, ref
  end
end
