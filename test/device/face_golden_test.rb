# Lock the call-sequence canonical dump of each Face class against a golden
# file in spec/golden/face_<name>.dump. Deviation from spec's "RGB565 buffer
# SHA" wording: pure-Ruby Face classes are deterministic in their draw call
# sequence, so a canonical dump catches any geometry drift (constants,
# formulas, method overrides). LCD readback is not available on device.
# HITL calibration validates visual correctness once, then the dump locks
# the geometry for all future regression runs.
class FaceGoldenTest < Picotest::Test
  # picotest loads this class from a generated /tmp driver, so File.dirname(__FILE__)
  # points at /tmp, not at the repo, so resolving spec/golden against it yields a
  # path that does not exist. test/picotest/harness.rb exports the repo root for
  # exactly this.
  GOLDEN_DIR = File.join(ENV["STACKCHAN_REPO_ROOT"].to_s, "spec", "golden")

  FACE_CASES = FaceGoldenHash::FACE_CASES

  def self.compute_dump(face_class) = FaceGoldenHash.compute_dump(face_class)

  FACE_CASES.each do |name, klass|
    define_method("test_#{name}_matches_golden") do
      golden_path = File.join(GOLDEN_DIR, "face_#{name}.dump")
      actual = self.class.compute_dump(klass)
      # Raise rather than skip. A skip makes an unreadable golden indistinguishable
      # from a passing one, which is how a wrong GOLDEN_DIR reports all seven faces
      # green while asserting nothing.
      unless File.exist?(golden_path)
        raise "no golden at #{golden_path}; run `rake face:register_golden FACE=#{name}`"
      end
      expected = File.read(golden_path)
      assert_equal expected, actual
    end
  end
end
