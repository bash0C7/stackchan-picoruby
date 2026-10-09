# Plain module (no Test::Unit dependency) — safe to require from Rake tasks
# without triggering the test runner's at-exit hook.
#
# face_golden_test.rb delegates to these methods so the serialization format
# stays a single source of truth between registration and assertion.
module FaceGoldenHash
  FACE_CASES = {
    neutral:   StackChan::Robot::Face.new,
    smile:     StackChan::Robot::Face.new(mouth: 8),
    joy:       StackChan::Robot::Face.new(mouth: 18),
    surprised: StackChan::Robot::Face.new(mouth: :open),
    sad:       StackChan::Robot::Face.new(mouth: -8),
    angry:     StackChan::Robot::Face.new(brows: :angry),
    closed:    StackChan::Robot::Face.new(eyes: :closed, mouth: :none),
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
        # sort_by is unavailable on PicoRuby — use sort with an explicit comparator
        "{" + a.to_a.sort { |x, y| x[0].to_s <=> y[0].to_s }.map { |k, v| "#{k}:#{v}" }.join(",") + "}"
      else
        a.to_s
      end
    end
    "#{method}|#{parts.join(",")}"
  end

  def self.canonical_dump(calls)
    calls.map { |c| serialize_call(c) }.join("\n")
  end

  def self.compute_dump(face)
    display = FakeDisplay.new
    face.draw(display)
    canonical_dump(display.calls)
  end
end
