require "digest"

# Plain module (no Test::Unit dependency) — safe to require from Rake tasks
# without triggering the test runner's at-exit hook.
#
# face_golden_test.rb delegates to these methods so the serialization format
# stays a single source of truth between registration and assertion.
module FaceGoldenHash
  FACE_CASES = {
    neutral:   StackchanApp::Face::Neutral,
    smile:     StackchanApp::Face::Smile,
    joy:       StackchanApp::Face::Joy,
    surprised: StackchanApp::Face::Surprised,
    sad:       StackchanApp::Face::Sad,
    angry:     StackchanApp::Face::Angry,
    closed:    StackchanApp::Face::Closed,
  }.freeze
  # Deterministic string for a single FakeDisplay#calls entry:
  #   "method_name|arg0,arg1,...,argN-1,{fill:true/false}"
  # The trailing keyword-arg hash (when present) is serialized in sorted
  # key:value form so different Ruby hash insertion orders are still equal.
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
end
