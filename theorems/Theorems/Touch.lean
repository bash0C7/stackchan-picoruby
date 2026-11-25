namespace Theorems.Touch

def period : Nat := 50

structure Poll where
  now : Nat
  zone : Option Nat
  fails : Bool
  deriving DecidableEq, Repr

structure Read where
  last : Option Nat
  reacted : List Nat
  reported : List Nat
  deriving DecidableEq, Repr

def due (last : Option Nat) (now : Nat) : Bool :=
  match last with
  | none => true
  | some t => decide (t + period ≤ now)

def poll (handlers : List Nat) (last : Option Nat) (p : Poll) : Read :=
  if due last p.now then
    match p.zone with
    | none => ⟨some p.now, [], []⟩
    | some z => ⟨some p.now, if handlers.contains z then [z] else [], [z]⟩
  else ⟨last, [], []⟩

def polls (handlers : List Nat) : Option Nat → List Poll → List Nat × List Nat
  | _, [] => ([], [])
  | last, p :: rest =>
    let r := poll handlers last p
    let (reacted, reported) := polls handlers r.last rest
    (r.reacted ++ reacted, r.reported ++ reported)

def sensed : Option Nat → List Poll → List Nat
  | _, [] => []
  | last, p :: rest =>
    if due last p.now then p.zone.toList ++ sensed (some p.now) rest else sensed last rest

theorem every_touch_sensed_is_reported (handlers : List Nat) (last : Option Nat) (ps : List Poll) :
    (polls handlers last ps).2 = sensed last ps := by
  induction ps generalizing last with
  | nil => rfl
  | cons p rest ih =>
    simp only [polls, sensed, poll]
    split <;> rename_i hd
    · cases hz : p.zone <;> simp [ih]
    · simp [ih]

theorem a_reaction_runs_once_for_each_touch_on_its_zone (handlers : List Nat) (last : Option Nat) (ps : List Poll) :
    (polls handlers last ps).1 = (sensed last ps).filter handlers.contains := by
  induction ps generalizing last with
  | nil => rfl
  | cons p rest ih =>
    simp only [polls, sensed, poll]
    split <;> rename_i hd
    · cases hz : p.zone <;> simp [ih]
      split <;> simp_all
    · simp [ih]

theorem the_sensor_is_read_at_most_every_period (handlers : List Nat) (t : Nat) (p : Poll) (h : p.now < t + period) :
    poll handlers (some t) p = ⟨some t, [], []⟩ := by
  simp [poll, due]
  omega

inductive Call
  | face (name : String)
  | led (side : String) (r g b : Nat) (mode : String) (flash : Option Nat)
  | head (yawLeft yawRight pitchUp : Option Nat) (time : Nat)
  | text (s : String)
  deriving DecidableEq, Repr

inductive Effect
  | face (name : String) (shown : Bool)
  | animate (side : String) (r g b : Nat) (mode : String)
  | flash (side : String) (r g b : Nat) (ms : Nat)
  | move (yawLeft yawRight pitchUp : Option Nat) (time velocity : Nat)
  | subtitle (s : String)
  deriving DecidableEq, Repr

def effect (faces : List String) (current : String) : Call → Effect
  | .face n => if faces.contains n then .face n true else .face current false
  | .led s r g b m none => .animate s r g b m
  | .led s r g b _ (some ms) => .flash s r g b ms
  | .head yl yr pu t => .move yl yr pu t 0
  | .text s => .subtitle s

end Theorems.Touch
