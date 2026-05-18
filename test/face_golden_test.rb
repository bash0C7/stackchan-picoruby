require "test_helper"
require "face_golden_hash"

# Lock the call-sequence SHA of each Face class against a golden file in
# spec/golden/face_<name>.sha256. Deviation from spec's "RGB565 buffer SHA"
# wording: pure-Ruby Face classes are deterministic in their draw call
# sequence, so a SHA over canonicalized calls catches any geometry drift
# (constants, formulas, method overrides). LCD readback is not available on
# device. HITL calibration validates visual correctness once, then the SHA
# locks the geometry for all future regression runs.
class FaceGoldenTest < Test::Unit::TestCase
  GOLDEN_DIR = File.expand_path("../spec/golden", __dir__)

  FACE_CASES = FaceGoldenHash::FACE_CASES

  # Delegate to FaceGoldenHash so the Rake registration task and the test
  # assertions share a single serialization source of truth.
  def self.serialize_call(call) = FaceGoldenHash.serialize_call(call)
  def self.canonical_dump(calls) = FaceGoldenHash.canonical_dump(calls)
  def self.compute_sha(face_class) = FaceGoldenHash.compute_sha(face_class)

  FACE_CASES.each do |name, klass|
    define_method("test_#{name}_matches_golden") do
      golden_path = File.join(GOLDEN_DIR, "face_#{name}.sha256")
      actual_sha  = self.class.compute_sha(klass)
      unless File.exist?(golden_path)
        omit "no golden registered for face_#{name}; current SHA=#{actual_sha}; " \
             "HITL-approve visual then run `rake face:register_golden FACE=#{name}` to register"
      end
      expected_sha = File.read(golden_path).strip
      assert_equal expected_sha, actual_sha,
        "Face::#{klass.name.split('::').last} call-sequence SHA drift. " \
        "If geometry change is intentional, HITL-revalidate then re-register golden."
    end
  end
end
