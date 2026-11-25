namespace Theorems.Contract

inductive GateEvent | helloOurs | helloTheirs | call | reset | garbage
  deriving DecidableEq, Repr

def gateStep (opened : Bool) : GateEvent → Bool × Bool
  | .helloOurs => (true, true)
  | .helloTheirs => (true, opened)
  | .call => (opened, opened)
  | .reset => (false, false)
  | .garbage => (false, opened)

def gateAfter (es : List GateEvent) : Bool :=
  es.foldl (fun o e => (gateStep o e).2) false

def decisive (e : GateEvent) : Bool :=
  e == .helloOurs || e == .reset

def latestWord (o : Bool) (r : List GateEvent) : Bool :=
  match r.find? decisive with
  | some e => e == .helloOurs
  | none => o

theorem replaying_newest_first (r : List GateEvent) (o : Bool) :
    r.foldr (fun e o => (gateStep o e).2) o = latestWord o r := by
  induction r with
  | nil => rfl
  | cons e r ih =>
    simp only [List.foldr_cons, ih]
    cases e <;> simp [latestWord, gateStep, decisive]

theorem the_gate_is_open_exactly_when_the_latest_word_was_a_matching_hello (es : List GateEvent) :
    gateAfter es = (es.reverse.find? decisive == some .helloOurs) := by
  unfold gateAfter
  rw [List.foldl_eq_foldr_reverse, replaying_newest_first]
  unfold latestWord
  split <;> rename_i h <;> simp [h]

theorem a_call_is_answered_only_after_a_matching_hello (pre : List GateEvent)
    (h : (gateStep (gateAfter pre) .call).1 = true) : pre.reverse.find? decisive = some .helloOurs := by
  simp only [gateStep] at h
  rw [the_gate_is_open_exactly_when_the_latest_word_was_a_matching_hello] at h
  simpa using h

end Theorems.Contract
