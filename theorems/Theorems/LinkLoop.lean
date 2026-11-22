namespace Theorems.LinkLoop

inductive Packet | none | arrived | disconnected | other | notAString
  deriving DecidableEq, Repr

structure TickIn where
  now : Nat
  packet : Packet
  traffic : Bool
  played : Option Nat
  deriving DecidableEq, Repr

def onPacket (now : Nat) (active : Option Nat) : Packet → Option Nat
  | .arrived => some now
  | .disconnected => Option.none
  | _ => active

def heard (i : TickIn) (active : Option Nat) : Option Nat :=
  if i.traffic then some i.now else onPacket i.now active i.packet

def overdue (release : Option Nat) (now : Nat) : Option Nat → Bool
  | some a => match release with
    | some r => decide (a + r ≤ now)
    | Option.none => false
  | Option.none => false

def afterPlay (i : TickIn) : Option Nat → Option Nat
  | some a => match i.played with
    | some ms => some (i.now + ms)
    | Option.none => some a
  | Option.none => Option.none

def tick (release : Option Nat) (i : TickIn) (active : Option Nat) : Option Nat × Bool :=
  let a := heard i active
  let cut := overdue release i.now a
  (afterPlay i (if cut then Option.none else a), cut)

def ticks (release : Option Nat) : List TickIn → Option Nat → Option Nat × List Nat
  | [], a => (a, [])
  | i :: rest, a =>
    let (a₁, cut) := tick release i a
    let (a₂, cuts) := ticks release rest a₁
    (a₂, (if cut then [i.now] else []) ++ cuts)

theorem without_release_after_nobody_is_cut (i : TickIn) (a : Option Nat) : (tick Option.none i a).2 = false := by
  unfold tick
  cases heard i a <;> simp [overdue]

theorem no_central_no_cut (release : Option Nat) (i : TickIn) (hp : i.packet ≠ .arrived) (ht : i.traffic = false) :
    (tick release i Option.none).2 = false := by
  unfold tick heard
  cases hq : i.packet <;> simp_all [onPacket, overdue]

theorem a_cut_is_not_repeated (release : Option Nat) (i j : TickIn) (a : Option Nat)
    (hc : (tick release i a).2 = true) (hp : j.packet ≠ .arrived) (ht : j.traffic = false) :
    (tick release j (tick release i a).1).2 = false := by
  have : (tick release i a).1 = Option.none := by
    unfold tick at hc ⊢
    simp only at hc
    simp [hc, afterPlay]
  rw [this]
  exact no_central_no_cut release j hp ht

theorem traffic_is_never_cut (r : Nat) (hr : 0 < r) (i : TickIn) (a : Option Nat) (ht : i.traffic = true) :
    (tick (some r) i a).2 = false := by
  simp [tick, heard, ht, overdue]
  omega

theorem a_disconnect_forgets_the_central (release : Option Nat) (i : TickIn) (a : Option Nat)
    (hp : i.packet = .disconnected) (ht : i.traffic = false) : (tick release i a).1 = Option.none := by
  simp [tick, heard, ht, hp, onPacket, overdue, afterPlay]

theorem traffic_renews (r : Nat) (hr : 0 < r) (i : TickIn) (a : Option Nat) (ht : i.traffic = true)
    (hp : i.played = none) : tick (some r) i a = (some i.now, false) := by
  have h : decide (i.now + r ≤ i.now) = false := by simp; omega
  simp only [tick, heard, ht, ite_true, overdue, h, afterPlay, hp]
  rfl

theorem a_fresh_central_stays (r : Nat) (i : TickIn) (a : Nat) (ht : i.traffic = false) (ha : i.packet ≠ .arrived)
    (hd : i.packet ≠ .disconnected) (hp : i.played = none) (hf : i.now < a + r) :
    tick (some r) i (some a) = (some a, false) := by
  have h : ¬ a + r ≤ i.now := by omega
  have hon : onPacket i.now (some a) i.packet = some a := by cases hq : i.packet <;> simp_all [onPacket]
  simp [tick, heard, ht, hon, overdue, h, afterPlay, hp]

theorem an_overdue_central_is_cut (r : Nat) (i : TickIn) (a : Nat) (ht : i.traffic = false) (ha : i.packet ≠ .arrived)
    (hd : i.packet ≠ .disconnected) (hf : a + r ≤ i.now) : (tick (some r) i (some a)).2 = true := by
  have hon : onPacket i.now (some a) i.packet = some a := by cases hq : i.packet <;> simp_all [onPacket]
  simp [tick, heard, ht, hon, overdue, hf]

end Theorems.LinkLoop
