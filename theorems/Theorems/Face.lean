namespace Theorems.Face

inductive FaceEvent | close | reopen | torqueOn | torqueOff | show (index : String)
  deriving DecidableEq, Repr

structure Faces where
  index : List (String × String)
  openEyed : List String
  deriving DecidableEq, Repr

structure Look where
  face : String
  waiting : Bool
  deriving DecidableEq, Repr

def shown (t : Faces) (i : String) : Option String :=
  (t.index.find? (·.1 == i)).map (·.2)

def step (t : Faces) (l : Look) : FaceEvent → Look × Bool
  | .close => ({ l with waiting := true }, false)
  | .reopen => ({ l with waiting := false }, l.waiting && t.openEyed.contains l.face)
  | .torqueOn => ({ l with face := "neutral" }, t.openEyed.contains "neutral")
  | .torqueOff => ({ l with face := "closed" }, false)
  | .show i => match shown t i with
    | some f => ({ l with face := f }, t.openEyed.contains f)
    | none => (l, false)

def idle : FaceEvent → Bool
  | .close | .reopen | .torqueOff => true
  | _ => false

def run (t : Faces) : Look → List FaceEvent → Look × Bool
  | l, [] => (l, false)
  | l, e :: rest =>
    let (l₁, opened) := step t l e
    let (last, later) := run t l₁ rest
    (last, opened || later)

theorem an_idle_robot_keeps_its_eyes_closed (t : Faces) (closed : t.openEyed.contains "closed" = false)
    (es : List FaceEvent) (h : es.all idle = true) (w : Bool) :
    (run t ⟨"closed", w⟩ es).1.face = "closed" ∧ (run t ⟨"closed", w⟩ es).2 = false := by
  induction es generalizing w with
  | nil => simp [run]
  | cons e rest ih =>
    simp only [List.all_cons, Bool.and_eq_true] at h
    obtain ⟨he, hr⟩ := h
    cases e <;> cases w <;> simp_all [idle, run, step]

end Theorems.Face
