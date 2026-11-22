namespace Theorems.Link

inductive State | released | held | quiet | busy
  deriving DecidableEq, Repr

inductive Keepalive | empty | zone | connectionError | timeout | timeoutLost
  deriving DecidableEq, Repr

inductive Body | ok | connectionError | timeout | timeoutLost | otherError | okLost
  deriving DecidableEq, Repr

inductive Call | connect | keepalive | reset
  deriving DecidableEq, Repr

inductive Result | ok | busy | connectionError | timeoutError | otherError
  deriving DecidableEq, Repr

structure Link where
  state : State
  lastAction : Nat
  lastSent : Nat
  touches : Nat
  releases : Nat
  connects : Nat
  deriving DecidableEq, Repr

structure Config where
  hold : Option Nat
  keepalive : Nat
  deriving DecidableEq, Repr

structure TickIn where
  now : Nat
  expire : Bool
  drainLoses : Bool
  reply : Keepalive
  deriving DecidableEq, Repr

structure ActIn where
  now : Nat
  drainLoses : Bool
  connects : Bool
  body : Body
  deriving DecidableEq, Repr

structure ActOut where
  link : Link
  calls : List Call
  ran : Nat
  result : Result
  deriving DecidableEq, Repr

def lose (l : Link) : Link :=
  { l with state := .released, releases := l.releases + 1, touches := 0 }

def use (now : Nat) (l : Link) : Link :=
  { l with state := .held, lastAction := now, lastSent := now }

def expired (c : Config) (i : TickIn) (l : Link) : Bool :=
  i.expire && match c.hold with
    | some hold => decide (l.lastAction + hold ≤ i.now)
    | none => false

def answer (r : Keepalive) (l : Link) : Link × List Call :=
  match r with
  | .empty => (l, [.keepalive])
  | .zone => ({ l with touches := l.touches + 1 }, [.keepalive])
  | .connectionError => (lose l, [.keepalive, .reset])
  | .timeout => ({ l with state := .quiet }, [.keepalive])
  | .timeoutLost => (lose l, [.keepalive, .reset])

def tick (c : Config) (i : TickIn) (l : Link) : Link × List Call :=
  match l.state with
  | .released => (l, [])
  | .busy => (l, [])
  | .quiet => if i.drainLoses then (lose l, [.reset]) else (l, [])
  | .held =>
    if i.drainLoses then (lose l, [.reset])
    else if expired c i l then ({ l with state := .quiet }, [])
    else if i.now < l.lastSent + c.keepalive then (l, [])
    else answer i.reply { l with lastSent := i.now }

def connected : State → Bool
  | .held | .quiet => true
  | _ => false

def runBody (i : ActIn) (l : Link) (calls : List Call) : ActOut :=
  match i.body with
  | .ok => ⟨use i.now l, calls, 1, .ok⟩
  | .okLost => ⟨lose l, calls ++ [.reset], 1, .ok⟩
  | .connectionError => ⟨lose l, calls ++ [.reset], 1, .connectionError⟩
  | .timeout => ⟨l, calls, 1, .timeoutError⟩
  | .timeoutLost => ⟨lose l, calls ++ [.reset], 1, .timeoutError⟩
  | .otherError => ⟨l, calls, 1, .otherError⟩

def act (i : ActIn) (l : Link) : ActOut :=
  let dropped := connected l.state && i.drainLoses
  let l₁ := if dropped then lose l else l
  let calls := if dropped then [Call.reset] else []
  if connected l₁.state then runBody i l₁ calls
  else if i.connects then runBody i (use i.now { l₁ with connects := l₁.connects + 1 }) (calls ++ [.connect])
  else ⟨{ l₁ with state := .busy }, calls ++ [.connect], 0, .busy⟩

def ticks (c : Config) : List TickIn → Link → Link × List Nat
  | [], l => (l, [])
  | i :: rest, l =>
    let (l₁, calls) := tick c i l
    let (l₂, sent) := ticks c rest l₁
    (l₂, (if Call.keepalive ∈ calls then [i.now] else []) ++ sent)

theorem tick_never_connects (c : Config) (i : TickIn) (l : Link) : Call.connect ∉ (tick c i l).2 := by
  unfold tick
  split <;> (try split) <;> (try split) <;> (try split) <;> simp_all
  unfold answer
  split <;> simp

theorem tick_is_silent_when_the_link_is_not_ours (c : Config) (i : TickIn) (l : Link)
    (h : connected l.state = false) : tick c i l = (l, []) := by
  unfold tick
  cases hs : l.state <;> simp_all [connected]

theorem quiet_never_speaks (c : Config) (i : TickIn) (l : Link) (h : l.state = .quiet) :
    Call.keepalive ∉ (tick c i l).2 := by
  unfold tick
  rw [h]
  cases i.drainLoses <;> simp

theorem tick_keeps_the_last_action (c : Config) (i : TickIn) (l : Link) :
    (tick c i l).1.lastAction = l.lastAction := by
  unfold tick
  split <;> (try split) <;> (try split) <;> (try split) <;> simp_all [lose]
  unfold answer
  split <;> simp [lose]

theorem a_keepalive_is_sent_only_inside_the_hold (c : Config) (hold : Nat) (hc : c.hold = some hold)
    (i : TickIn) (l : Link) (he : i.expire = true) (hk : Call.keepalive ∈ (tick c i l).2) :
    i.now < l.lastAction + hold := by
  unfold tick at hk
  split at hk <;> try simp at hk
  · split at hk <;> simp at hk
  · split at hk
    · simp at hk
    · split at hk
      · simp at hk
      · rename_i hx
        simp [expired, he, hc] at hx
        omega

theorem every_keepalive_is_sent_inside_the_hold (c : Config) (hold : Nat) (hc : c.hold = some hold)
    (is : List TickIn) (l : Link) (he : ∀ i ∈ is, i.expire = true) :
    ∀ s ∈ (ticks c is l).2, s < l.lastAction + hold := by
  induction is generalizing l with
  | nil => simp [ticks]
  | cons i rest ih =>
    intro s hs
    simp only [ticks, List.mem_append] at hs
    cases hs with
    | inl h =>
      split at h
      · rename_i hk
        simp only [List.mem_singleton] at h
        subst h
        exact a_keepalive_is_sent_only_inside_the_hold c hold hc i l (he i (by simp)) hk
      · simp at h
    | inr h =>
      have := ih (tick c i l).1 (fun j hj => he j (by simp [hj])) s h
      rwa [tick_keeps_the_last_action] at this

theorem a_held_link_speaks_at_least_every_keepalive (c : Config) (i : TickIn) (l : Link)
    (h : (tick c i l).1.state = .held) : i.now < (tick c i l).1.lastSent + c.keepalive ∨
      (tick c i l).1.lastSent = i.now := by
  unfold tick at h ⊢
  split at h <;> rename_i hs
  · simp [hs] at h
  · simp [hs] at h
  · split at h <;> simp_all [lose]
  · split at h
    · simp [lose] at h
    · split at h
      · simp at h
      · split at h
        · rename_i a b d
          simp [a, b, d]
        · rename_i a b d
          simp only [hs, a, b, d]
          cases hr : i.reply <;> simp_all [answer, lose]

theorem act_tries_at_most_one_connect (i : ActIn) (l : Link) : (act i l).calls.count .connect ≤ 1 := by
  obtain ⟨now, d, ok, body⟩ := i
  obtain ⟨st, la, ls, t, r, n⟩ := l
  cases st <;> cases d <;> cases ok <;> cases body <;> simp [act, runBody, connected, lose, use]

theorem an_action_body_runs_at_most_once (i : ActIn) (l : Link) : (act i l).ran ≤ 1 := by
  obtain ⟨now, d, ok, body⟩ := i
  obtain ⟨st, la, ls, t, r, n⟩ := l
  cases st <;> cases d <;> cases ok <;> cases body <;> simp [act, runBody, connected, lose, use]

theorem busy_means_the_body_never_ran (i : ActIn) (l : Link) (h : (act i l).result = .busy) :
    (act i l).ran = 0 ∧ (act i l).link.state = .busy := by
  obtain ⟨now, d, ok, body⟩ := i
  obtain ⟨st, la, ls, t, r, n⟩ := l
  cases st <;> cases d <;> cases ok <;> cases body <;> simp_all [act, runBody, connected, lose, use]

theorem a_successful_action_restarts_the_hold (i : ActIn) (l : Link) (h : (act i l).result = .ok)
    (held : (act i l).link.state ≠ .released) :
    (act i l).link.state = .held ∧ (act i l).link.lastAction = i.now := by
  obtain ⟨now, d, ok, body⟩ := i
  obtain ⟨st, la, ls, t, r, n⟩ := l
  cases st <;> cases d <;> cases ok <;> cases body <;> simp_all [act, runBody, connected, lose, use]

end Theorems.Link
