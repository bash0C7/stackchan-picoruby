namespace Theorems.Remote

def touchCap : Nat := 16

inductive Event | touch (zone : Nat) | take | begin | chunk (bytes : Nat) | play | perform | done
  deriving DecidableEq, Repr

inductive Out | nothing | zones (zs : List Nat) | size (n : Nat) | flag (b : Bool)
  deriving DecidableEq, Repr

structure State where
  touches : List Nat
  buffered : Nat
  pending : Bool
  finished : Bool
  deriving DecidableEq, Repr

def newest (l : List Nat) : List Nat :=
  l.drop (l.length - touchCap)

def push (q : List Nat) (z : Nat) : List Nat :=
  newest (q ++ [z])

def step (s : State) : Event → State × Out
  | .touch z => ({ s with touches := push s.touches z }, .nothing)
  | .take => ({ s with touches := [] }, .zones s.touches)
  | .begin => ({ s with buffered := 0, pending := false, finished := false }, .flag true)
  | .chunk n => ({ s with buffered := s.buffered + n }, .size (s.buffered + n))
  | .play => ({ s with pending := true }, .flag true)
  | .perform => if s.pending then ({ s with pending := false, finished := true }, .nothing) else (s, .nothing)
  | .done => (s, .flag s.finished)

def run (s : State) (es : List Event) : State :=
  es.foldl (fun s e => (step s e).1) s

theorem newest_absorbs (l m : List Nat) : newest (newest l ++ m) = newest (l ++ m) := by
  unfold newest
  simp only [List.drop_append, List.drop_drop, List.length_drop, List.length_append]
  congr 1 <;> congr 1 <;> omega

theorem pushing_keeps_the_newest (q zs : List Nat) : zs.foldl push (newest q) = newest (q ++ zs) := by
  induction zs generalizing q with
  | nil => simp
  | cons z zs ih =>
    rw [List.foldl_cons, push, newest_absorbs, ih (q ++ [z])]
    simp

theorem the_robot_reports_the_newest_touches_in_order (zs : List Nat) (s : State) (h : s.touches = []) :
    (step (run s (zs.map .touch)) .take).2 = .zones (zs.drop (zs.length - touchCap)) := by
  have : ∀ (t : State), (run t (zs.map .touch)).touches = zs.foldl push t.touches := by
    induction zs with
    | nil => simp [run]
    | cons z zs ih =>
      intro t
      simp only [run, List.map_cons, List.foldl_cons] at ih ⊢
      exact ih { t with touches := push t.touches z }
  have e : zs.foldl push [] = newest zs := by simpa [newest] using pushing_keeps_the_newest [] zs
  simp [step, this, h, e, newest]

theorem taking_empties_the_touches (s : State) : (step s .take).1.touches = [] := rfl

theorem every_touch_is_reported_when_taken_often_enough (zs : List Nat) (s : State) (h : s.touches = [])
    (few : zs.length ≤ touchCap) : (step (run s (zs.map .touch)) .take).2 = .zones zs := by
  rw [the_robot_reports_the_newest_touches_in_order zs s h]
  simp [Nat.sub_eq_zero_of_le few]

def plays (e : Event) : Bool := e == .play

def performs (e : Event) : Bool := e == .perform

theorem a_clip_is_done_only_after_it_was_played (s : State) (es : List Event)
    (h : es.all (fun e => !plays e) = true ∨ es.all (fun e => !performs e) = true) :
    (run (step s .begin).1 es).finished = false := by
  have keep : ∀ (t : State) (es : List Event), t.finished = false → t.pending = false →
      es.all (fun e => !plays e) = true → (run t es).finished = false ∧ (run t es).pending = false := by
    intro t es hf hp hn
    induction es generalizing t with
    | nil => simp [run, hf, hp]
    | cons e rest ih =>
      simp only [List.all_cons, Bool.and_eq_true] at hn
      simp only [run, List.foldl_cons] at ih ⊢
      apply ih _ _ _ hn.2 <;> cases e <;> simp_all [step, plays]
  have still : ∀ (t : State) (es : List Event), t.finished = false →
      es.all (fun e => !performs e) = true → (run t es).finished = false := by
    intro t es hf hn
    induction es generalizing t with
    | nil => simp [run, hf]
    | cons e rest ih =>
      simp only [List.all_cons, Bool.and_eq_true] at hn
      simp only [run, List.foldl_cons] at ih ⊢
      apply ih _ _ hn.2
      cases e <;> simp_all [step, performs]
  cases h with
  | inl hp => exact (keep _ es rfl rfl hp).1
  | inr hq => exact still _ es rfl hq

theorem a_played_clip_is_reported_done (s : State) (chunks : List Nat) :
    (step (run (step s .begin).1 (chunks.map .chunk ++ [.play, .perform])) .done).2 = .flag true := by
  have : ∀ (t : State), (run t (chunks.map .chunk)).pending = t.pending := by
    induction chunks with
    | nil => simp [run]
    | cons c cs ih =>
      intro t
      simp only [run, List.map_cons, List.foldl_cons] at ih ⊢
      exact ih _
  simp [run, List.foldl_append] at this ⊢
  simp [step]

end Theorems.Remote
