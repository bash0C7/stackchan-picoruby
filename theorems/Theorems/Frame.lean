namespace Theorems.Frame

abbrev Frame := List (String × String)

def frameKeys : List String := ["F", "L", "R", "G", "B", "S", "M", "text", "YL", "YR", "PU", "T", "V"]

def systemKeys : List String := ["torque", "selftest", "read"]

def ledKeys : List String := ["L", "R", "G", "B", "S", "M"]

def headKeys : List String := ["YL", "YR", "PU"]

def sides : List String := ["L", "R", "B"]

def modes : List String := ["s", "b", "p", "o"]

structure Tables where
  faces : List String
  handlers : List (String × Bool)
  head : Bool
  deriving DecidableEq, Repr

structure Outcome where
  reply : String
  face : Bool
  led : Bool
  text : Bool
  servo : Bool
  torque : Bool
  handlers : Nat
  deriving DecidableEq, Repr

def lookup (f : Frame) (k : String) : Option String :=
  (f.find? (·.1 == k)).map (·.2)

def has (f : Frame) (k : String) : Bool :=
  (lookup f k).isSome

def anyKey (f : Frame) (keys : List String) : Bool :=
  keys.any (has f)

def digitsValue : List Char → Nat → Nat
  | [], acc => acc
  | c :: rest, acc => digitsValue rest (acc * 10 + (c.toNat - '0'.toNat))

def number (s : String) (max : Nat) : Bool :=
  let cs := s.toList
  0 < cs.length && cs.length ≤ 5 && cs.all Char.isDigit && decide (digitsValue cs 0 ≤ max)

def numbers (f : Frame) (keys : List String) (max : Nat) : Bool :=
  keys.all fun k => match lookup f k with
    | some v => number v max
    | none => true

def handled (t : Tables) (k : String) : Bool :=
  t.handlers.any (·.1 == k)

def validLed (f : Frame) : Bool :=
  lookup f "L" == some "1" && (lookup f "M").any modes.contains && (lookup f "S").any sides.contains &&
    numbers f ["R", "G", "B"] 255

def valid (t : Tables) (f : Frame) : Bool :=
  !f.isEmpty &&
  f.all (fun (k, _) => handled t k || frameKeys.contains k) &&
  (!has f "F" || (lookup f "F").any t.faces.contains) &&
  (!anyKey f ledKeys || validLed f) &&
  (if anyKey f headKeys then numbers f headKeys 100 && numbers f ["T", "V"] 65535
   else !has f "T" && !has f "V") &&
  (f.any (fun (k, _) => handled t k) || has f "F" || has f "L" || has f "text" || anyKey f headKeys)

def handlersPass (t : Tables) (f : Frame) : Bool :=
  t.handlers.all fun (k, ok) => !has f k || ok

def handlersCalled (t : Tables) (f : Frame) : Nat :=
  (t.handlers.filter fun (k, _) => has f k).length

def refused : Outcome := ⟨"?", false, false, false, false, false, 0⟩

def system (t : Tables) (f : Frame) : Outcome :=
  if f.length != 1 then refused
  else match f with
    | [("torque", "on")] | [("torque", "off")] => ⟨".", true, false, false, false, t.head, 0⟩
    | [("selftest", "run")] => if t.head then ⟨".", false, false, false, true, false, 0⟩ else refused
    | [("read", "pos")] => if t.head then ⟨".", false, false, false, false, false, 0⟩ else refused
    | _ => refused

def spec (t : Tables) (f : Frame) : Outcome :=
  if anyKey f systemKeys then system t f
  else if !valid t f then refused
  else if !handlersPass t f then { refused with handlers := handlersCalled t f }
  else ⟨".", has f "F", has f "L", has f "text", t.head && anyKey f headKeys, false, handlersCalled t f⟩

theorem a_refused_frame_changes_nothing_the_engine_owns (t : Tables) (f : Frame) (h : (spec t f).reply = "?") :
    (spec t f).face = false ∧ (spec t f).led = false ∧ (spec t f).text = false ∧ (spec t f).servo = false ∧
      (spec t f).torque = false := by
  unfold spec at *
  by_cases hs : anyKey f systemKeys = true
  · simp only [hs, ite_true] at *
    unfold system at *
    by_cases hl : (f.length != 1) = true
    · simp only [hl, ite_true] at *
      simp [refused]
    · simp only [hl, Bool.false_eq_true, ite_false] at *
      split <;> (try split) <;> simp_all [refused]
  · simp only [hs, Bool.false_eq_true, ite_false] at *
    by_cases hv : valid t f = true
    · by_cases hp : handlersPass t f = true
      · simp [hv, hp] at h
      · simp [hv, hp, refused]
    · simp [hv, refused]

theorem an_accepted_frame_did_every_part (t : Tables) (f : Frame) (h : (spec t f).reply = ".")
    (plain : anyKey f systemKeys = false) :
    (spec t f).face = has f "F" ∧ (spec t f).led = has f "L" ∧ (spec t f).text = has f "text" ∧
      (spec t f).servo = (t.head && anyKey f headKeys) := by
  unfold spec at *
  simp only [plain, Bool.false_eq_true, ite_false] at *
  by_cases hv : valid t f = true
  · by_cases hp : handlersPass t f = true
    · simp [hv, hp]
    · simp [hv, hp, refused] at h
  · simp [hv, refused] at h

def yawLeft (m : Nat) : Int := 482 - (m * 300 / 100 : Nat)

def yawRight (m : Nat) : Int := 482 + (m * 300 / 100 : Nat)

def pitchUp (m : Nat) : Int := 633 + (m * 296 / 100 : Nat)

theorem the_head_stays_in_its_range (m : Nat) (hm : m ≤ 100) :
    182 ≤ yawLeft m ∧ yawLeft m ≤ 482 ∧ 482 ≤ yawRight m ∧ yawRight m ≤ 782 ∧ 633 ≤ pitchUp m ∧ pitchUp m ≤ 929 := by
  simp only [yawLeft, yawRight, pitchUp]
  omega
def classes : List (String × List String) := [
  ("F", ["1", "9"]), ("L", ["1", "2"]), ("R", ["0", "255", "256", "x"]), ("G", ["255", "256"]), ("B", ["255", "x"]),
  ("S", ["B", "X"]), ("M", ["s", "x"]), ("text", ["hi"]), ("YL", ["0", "100", "101", "x"]), ("YR", ["100", "101"]),
  ("PU", ["100", "x"]), ("T", ["65535", "65536"]), ("V", ["0", "x"]), ("torque", ["on", "off", "x"]),
  ("selftest", ["run", "x"]), ("read", ["pos", "x"]), ("other", ["1"])
]

def handlerClasses : List (String × List String) := [("glow", ["1"]), ("dim", ["1"])]

def singles (cs : List (String × List String)) : List Frame :=
  cs.flatMap fun (k, vs) => vs.map fun v => [(k, v)]

def pairsFrom : List (String × List String) → List Frame
  | [] => []
  | (k, vs) :: rest =>
    (vs.flatMap fun v => rest.flatMap fun (k₂, vs₂) => vs₂.map fun v₂ => [(k, v), (k₂, v₂)]) ++ pairsFrom rest

def fullLeds : List Frame :=
  ["1", "2"].flatMap fun l => ["B", "X"].flatMap fun side => ["s", "x"].flatMap fun mode =>
    ["0", "255", "256", "x"].map fun r => [("L", l), ("R", r), ("G", "0"), ("B", "0"), ("S", side), ("M", mode)]

def fullHeads : List Frame :=
  ["0", "100", "101", "x"].flatMap fun yl => ["100", "x"].flatMap fun pu => ["65535", "65536"].map fun t =>
    [("YL", yl), ("PU", pu), ("T", t)]

def appFrames : List Frame :=
  singles classes ++ pairsFrom classes ++ fullLeds ++ fullHeads

def handlerFrames : List Frame :=
  singles handlerClasses ++ pairsFrom (handlerClasses ++ [("F", ["1", "9"]), ("other", ["1"])])

end Theorems.Frame
