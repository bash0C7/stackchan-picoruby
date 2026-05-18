require "test_helper"
require "digest"

# Lock the call-sequence SHA of each Face class against a golden file in
# spec/golden/face_<name>.sha256. Deviation from spec's "RGB565 buffer SHA"
# wording: pure-Ruby Face classes are deterministic in their draw call
# sequence, so a SHA over canonicalized calls catches any geometry drift
# (constants, formulas, method overrides). LCD readback is not available on
# device. HITL calibration validates visual correctness once, then the SHA
# locks the geometry for all future regression runs.
class FaceGoldenTest < Test::Unit::TestCase
  GOLDEN_DIR = File.expand_path("../spec/golden", __dir__)

  FACE_CASES = {
    neutral:   StackchanProtocol::Face::Neutral,
    smile:     StackchanProtocol::Face::Smile,
    joy:       StackchanProtocol::Face::Joy,
    surprised: StackchanProtocol::Face::Surprised,
    sad:       StackchanProtocol::Face::Sad,
    angry:     StackchanProtocol::Face::Angry,
  }.freeze

  # Deterministic string for a single FakeDisplay#calls entry:
  #   "method_name|arg0,arg1,...,argN-1,{fill:true/false}"
  # The trailing keyword-arg hash (when present) is serialized in key:value
  # form so different Ruby hash insertion orders are still equal.
  def self.serialize_call(call)
    method, args = call
    parts = args.map do |a|
      case a
      when Hash
        "{" + a.sort_by { |k, _| k.to_s }.map { |k, v| "#{k}:#{v}" }.join(",") + "}"
      else
        a.to_s
      end
    end
    "#{method}|#{parts.join(",")}"
  end

  def self.canonical_dump(calls)
    calls.map { |c| serialize_call(c) }.join("\n")
  end

  def self.compute_sha(face_class)
    display = FakeDisplay.new
    face_class.new.draw(display)
    Digest::SHA256.hexdigest(canonical_dump(display.calls))
  end

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
