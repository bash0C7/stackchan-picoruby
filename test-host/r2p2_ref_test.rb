require 'test/unit'
require 'yaml'

class R2p2RefTest < Test::Unit::TestCase
  ROOT = File.expand_path('..', __dir__)

  def test_the_rakefile_clones_the_r2p2_esp32_branch_the_trial_arm_pins
    rakefile = File.read(File.join(ROOT, 'Rakefile'))
    ref = rakefile[/^R2P2_ESP32_REF\s*=\s*ENV\["R2P2_ESP32_REF"\]\s*\|\|\s*"([^"]+)"/, 1]
    assert_not_nil ref, 'R2P2_ESP32_REF default not found in Rakefile'

    lock = File.read(File.join(ROOT, 'trial', 'lock.yml'))
    trial = lock[/^  trial:\n(.*?)(?=^  \S|\z)/m, 1]
    assert_not_nil trial, 'trial arm not found in trial/lock.yml'
    branch = trial[/^    R2P2-ESP32:\s*\h{40}\s*#\s*(\S+)/, 1]
    assert_not_nil branch, 'trial arm R2P2-ESP32 pin has no branch comment'

    assert_equal branch, ref
  end
end
