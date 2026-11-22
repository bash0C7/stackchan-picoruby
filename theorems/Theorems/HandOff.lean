import Theorems.Link
import Theorems.LinkLoop

namespace Theorems.HandOff

def Paced (gap : Nat) : Nat → List Nat → Prop
  | _, [] => True
  | p, t :: rest => p ≤ t ∧ t ≤ p + gap ∧ Paced gap t rest

def Increasing : Nat → List Nat → Prop
  | _, [] => True
  | p, t :: rest => p < t ∧ Increasing t rest

def letGo (release : Option Nat) (rs : List LinkLoop.TickIn) (active : Option Nat) (t : Nat) : Prop :=
  t ∈ (LinkLoop.ticks release rs active).2 ∨ ∃ i ∈ rs, i.packet = .disconnected ∧ i.now = t

theorem a_silent_central_is_let_go (release gap last : Nat) (hr : 0 < release) (rs : List LinkLoop.TickIn) :
    ∀ (a p : Nat), a ≤ last → p < last + release →
      Paced gap p (rs.map (·.now)) →
      (∀ i ∈ rs, i.packet ≠ .arrived ∧ i.played = none) →
      (∀ i ∈ rs, i.traffic = true → i.now ≤ last) →
      (∃ i ∈ rs, last + release ≤ i.now) →
      ∃ t, letGo (some release) rs (some a) t ∧ t < last + release + gap := by
  induction rs with
  | nil => intro a p _ _ _ _ _ ⟨i, hi, _⟩; simp at hi
  | cons i rest ih =>
    intro a p ha hp hpace hq hl ⟨w, hw, hwt⟩
    simp only [List.map_cons, Paced] at hpace
    obtain ⟨hpi, hig, hrest⟩ := hpace
    have hqi := hq i (by simp)
    have hi : i.now < last + release + gap := by omega
    by_cases hd : i.packet = .disconnected
    · exact ⟨i.now, Or.inr ⟨i, by simp, hd, rfl⟩, hi⟩
    · by_cases hcut : (LinkLoop.tick (some release) i (some a)).2 = true
      · exact ⟨i.now, Or.inl (by simp [LinkLoop.ticks, hcut]), hi⟩
      · have hstep : ∃ b, (LinkLoop.tick (some release) i (some a)).1 = some b ∧ b ≤ last ∧ i.now < b + release := by
          cases ht : i.traffic with
          | true => exact ⟨i.now, by rw [LinkLoop.traffic_renews release hr i _ ht hqi.2], hl i (by simp) ht, by omega⟩
          | false =>
            by_cases hf : i.now < a + release
            · exact ⟨a, by rw [LinkLoop.a_fresh_central_stays release i a ht hqi.1 hd hqi.2 hf], ha, hf⟩
            · exact absurd (LinkLoop.an_overdue_central_is_cut release i a ht hqi.1 hd (by omega)) hcut
        obtain ⟨b, hb, hbl, hbi⟩ := hstep
        have hwr : w ∈ rest := by
          rcases List.mem_cons.mp hw with h | h
          · subst h; omega
          · exact h
        obtain ⟨t, htg, htl⟩ := ih b i.now hbl (by omega) hrest (fun j hj => hq j (by simp [hj]))
          (fun j hj => hl j (by simp [hj])) ⟨w, hwr, hwt⟩
        refine ⟨t, ?_, htl⟩
        rcases htg with h | ⟨j, hj, hjd, hjt⟩
        · exact Or.inl (by simp only [LinkLoop.ticks, hb]; simp [h])
        · exact Or.inr ⟨j, by simp [hj], hjd, hjt⟩

structure Quietness (hold delivery gap t₀ : Nat) (c : Link.Config) (cs : List Link.TickIn) (l : Link.Link)
    (release : Nat) (rs : List LinkLoop.TickIn) (a : Nat) : Prop where
  lastActionAt : l.lastAction = t₀ / 1000
  noFurtherAction : ∀ i ∈ cs, i.expire = true
  robotTicks : Paced gap t₀ (rs.map (·.now))
  robotHeardTheAction : a ≤ t₀ + delivery
  noNewCentralNoAudio : ∀ i ∈ rs, i.packet ≠ .arrived ∧ i.played = none
  everythingHeardWasSent : ∀ i ∈ rs, i.traffic = true →
    i.now ≤ t₀ + delivery ∨ ∃ s ∈ (Link.ticks c cs l).2, i.now < (s + 1) * 1000 + delivery
  robotStaysUp : ∃ i ∈ rs, t₀ + hold * 1000 + delivery + release ≤ i.now

theorem the_robot_is_handed_over (hold delivery gap t₀ : Nat) (c : Link.Config) (hc : c.hold = some hold)
    (cs : List Link.TickIn) (l : Link.Link) (release : Nat) (hr : 0 < release) (rs : List LinkLoop.TickIn) (a : Nat)
    (q : Quietness hold delivery gap t₀ c cs l release rs a) :
    ∃ t, letGo (some release) rs (some a) t ∧ t < t₀ + hold * 1000 + delivery + release + gap := by
  refine a_silent_central_is_let_go release gap (t₀ + hold * 1000 + delivery) hr rs a t₀ ?_ ?_
    q.robotTicks q.noNewCentralNoAudio ?_ q.robotStaysUp
  · have := q.robotHeardTheAction; omega
  · omega
  · intro i hi ht
    rcases q.everythingHeardWasSent i hi ht with h | ⟨s, hs, h⟩
    · omega
    · have := Link.every_keepalive_is_sent_inside_the_hold c hold hc cs l q.noFurtherAction s hs
      have h0 := q.lastActionAt
      omega

theorem a_spoken_to_robot_never_cuts (release : Nat) (hr : 0 < release) (rs : List LinkLoop.TickIn) :
    ∀ a p : Nat, a ≤ p → Increasing p (rs.map (·.now)) →
      (∀ i ∈ rs, i.packet ≠ .arrived ∧ i.packet ≠ .disconnected ∧ i.played = none) →
      (∀ i ∈ rs, ∃ f, (f ≤ a ∨ ∃ j ∈ rs, j.traffic = true ∧ j.now = f) ∧ f ≤ i.now ∧ i.now < f + release) →
      (LinkLoop.ticks (some release) rs (some a)).2 = [] := by
  induction rs with
  | nil => intros; rfl
  | cons i rest ih =>
    intro a p hap hinc hq hf
    simp only [List.map_cons, Increasing] at hinc
    obtain ⟨hpi, hrest⟩ := hinc
    have later : ∀ (q : Nat) (xs : List LinkLoop.TickIn), Increasing q (xs.map (·.now)) → ∀ j ∈ xs, q < j.now := by
      intro q xs
      induction xs generalizing q with
      | nil => intro _ j hj; simp at hj
      | cons x xs ihx =>
        intro h j hj
        simp only [List.map_cons, Increasing] at h
        rcases List.mem_cons.mp hj with rfl | hj
        · exact h.1
        · have := ihx x.now h.2 j hj; omega
    have hqi := hq i (by simp)
    have key : ∃ b, LinkLoop.tick (some release) i (some a) = (some b, false) ∧ a ≤ b ∧ b ≤ i.now ∧
        (i.traffic = true → b = i.now) := by
      cases ht : i.traffic with
      | true =>
        exact ⟨i.now, LinkLoop.traffic_renews release hr i _ ht hqi.2.2, by omega, by omega, fun _ => rfl⟩
      | false =>
        have hfresh : ¬ a + release ≤ i.now := by
          obtain ⟨f, hsrc, hfi, hfr⟩ := hf i (by simp)
          rcases hsrc with h | ⟨j, hj, hjt, hjn⟩
          · omega
          · rcases List.mem_cons.mp hj with rfl | hj
            · simp [ht] at hjt
            · have := later i.now rest hrest j hj; omega
        exact ⟨a, LinkLoop.a_fresh_central_stays release i a ht hqi.1 hqi.2.1 hqi.2.2 (by omega), by omega, by omega,
          by simp⟩
    obtain ⟨b, hb, hab, hbi, htb⟩ := key
    have := ih b i.now hbi hrest (fun j hj => hq j (by simp [hj])) (by
      intro j hj
      obtain ⟨f, hsrc, h1, h2⟩ := hf j (by simp [hj])
      refine ⟨f, ?_, h1, h2⟩
      rcases hsrc with h | ⟨k, hk, hkt, hkn⟩
      · exact Or.inl (by omega)
      · rcases List.mem_cons.mp hk with rfl | hk
        · have := htb hkt; exact Or.inl (by omega)
        · exact Or.inr ⟨k, hk, hkt, hkn⟩)
    simp [LinkLoop.ticks, hb, this]

def Alive (c : Link.Config) (l : Link.Link) (i : Link.TickIn) : Prop :=
  i.drainLoses = false ∧ (i.reply = .empty ∨ i.reply = .zone) ∧
    (i.expire = false ∨ ∀ hold, c.hold = some hold → i.now < l.lastAction + hold)

theorem a_living_tick_stays_held (c : Link.Config) (i : Link.TickIn) (l : Link.Link) (hs : l.state = .held)
    (h : Alive c l i) : (Link.tick c i l).1.state = .held ∧
      ((i.now < l.lastSent + c.keepalive ∧ (Link.tick c i l).2 = [] ∧ (Link.tick c i l).1.lastSent = l.lastSent) ∨
       (l.lastSent + c.keepalive ≤ i.now ∧ (Link.tick c i l).2 = [.keepalive] ∧ (Link.tick c i l).1.lastSent = i.now)) := by
  obtain ⟨hd, hrep, hx⟩ := h
  have hne : Link.expired c i l = false := by
    unfold Link.expired
    rcases hx with h | h
    · simp [h]
    · cases hh : c.hold with
      | none => simp
      | some hold => have := h hold hh; simp; intro _; omega
  unfold Link.tick
  simp only [hs, hd, hne]
  by_cases hk : i.now < l.lastSent + c.keepalive
  · simp [hk, hs]
  · have hk' : l.lastSent + c.keepalive ≤ i.now := by omega
    rcases hrep with h | h <;> simp [hk, hk', h, Link.answer]

theorem a_held_controller_speaks_often (c : Link.Config) (gap : Nat) (hk : 0 < c.keepalive) (is : List Link.TickIn) :
    ∀ (l : Link.Link) (p : Nat), l.state = .held → l.lastSent ≤ p → p < l.lastSent + c.keepalive →
      Paced gap p (is.map (·.now)) →
      (∀ i ∈ is, i.drainLoses = false ∧ (i.reply = .empty ∨ i.reply = .zone) ∧
        (i.expire = false ∨ ∀ hold, c.hold = some hold → i.now < l.lastAction + hold)) →
      Paced (c.keepalive + gap) l.lastSent (Link.ticks c is l).2 := by
  induction is with
  | nil => intros; simp [Link.ticks, Paced]
  | cons i rest ih =>
    intro l p hs hlp hp hpace ha
    simp only [List.map_cons, Paced] at hpace
    obtain ⟨h1, h2, h3⟩ := hpace
    obtain ⟨held, hcase⟩ := a_living_tick_stays_held c i l hs (ha i (by simp))
    have hla := Link.tick_keeps_the_last_action c i l
    have hrest : ∀ j ∈ rest, j.drainLoses = false ∧ (j.reply = .empty ∨ j.reply = .zone) ∧
        (j.expire = false ∨ ∀ hold, c.hold = some hold → j.now < (Link.tick c i l).1.lastAction + hold) := by
      intro j hj; rw [hla]; exact ha j (by simp [hj])
    rcases hcase with ⟨hn, hc, hsent⟩ | ⟨hn, hc, hsent⟩
    · have := ih (Link.tick c i l).1 i.now held (by omega) (by omega) h3 hrest
      simp only [Link.ticks, hc]
      rw [hsent] at this
      simpa using this
    · have := ih (Link.tick c i l).1 i.now held (by omega) (by omega) h3 hrest
      rw [hsent] at this
      simp only [Link.ticks, hc]
      simp only [List.mem_singleton, ite_true, List.singleton_append, Paced]
      exact ⟨by omega, by omega, this⟩

def lastOf : Nat → List Nat → Nat
  | s, [] => s
  | _, t :: rest => lastOf t rest

theorem somebody_spoke_recently (gap delivery : Nat) (sent : List Nat) :
    ∀ s₀ x : Nat, Paced gap s₀ sent → s₀ * 1000 + delivery ≤ x →
      x < (lastOf s₀ sent + gap) * 1000 + delivery →
      ∃ s ∈ s₀ :: sent, s * 1000 + delivery ≤ x ∧ x < (s + gap) * 1000 + delivery := by
  induction sent with
  | nil => intro s₀ x _ h1 h2; simp only [lastOf] at h2; exact ⟨s₀, List.mem_cons_self, h1, h2⟩
  | cons s rest ih =>
    intro s₀ x hp h1 h2
    simp only [Paced] at hp
    by_cases hx : s * 1000 + delivery ≤ x
    · obtain ⟨t, ht, h3, h4⟩ := ih s x hp.2.2 hx h2
      exact ⟨t, List.mem_cons_of_mem _ ht, h3, h4⟩
    · have hstep := hp.2.1
      clear ih h2 hp
      exact ⟨s₀, List.mem_cons_self, h1, by omega⟩

structure Holding (delivery gap : Nat) (c : Link.Config) (cs : List Link.TickIn) (l : Link.Link) (p : Nat)
    (rs : List LinkLoop.TickIn) (a : Nat) : Prop where
  held : l.state = .held
  spokeBefore : l.lastSent ≤ p ∧ p < l.lastSent + c.keepalive
  controllerTicks : Paced gap p (cs.map (·.now))
  linkAlive : ∀ i ∈ cs, i.drainLoses = false ∧ (i.reply = .empty ∨ i.reply = .zone) ∧
    (i.expire = false ∨ ∀ hold, c.hold = some hold → i.now < l.lastAction + hold)
  robotHeardTheLast : l.lastSent * 1000 ≤ a ∧ a ≤ l.lastSent * 1000 + delivery
  robotTicks : Increasing (l.lastSent * 1000 + delivery) (rs.map (·.now))
  noNewCentralNoAudio : ∀ i ∈ rs, i.packet ≠ .arrived ∧ i.packet ≠ .disconnected ∧ i.played = none
  everythingSentIsHeard : ∀ s ∈ (Link.ticks c cs l).2, ∃ f, s * 1000 ≤ f ∧ f ≤ s * 1000 + delivery ∧
    (f ≤ a ∨ ∃ j ∈ rs, j.traffic = true ∧ j.now = f)
  whileTicking : ∀ i ∈ rs, i.now <
    (lastOf l.lastSent (Link.ticks c cs l).2 + (c.keepalive + gap)) * 1000 + delivery

theorem a_holding_controller_is_never_cut (delivery gap : Nat) (c : Link.Config) (hk : 0 < c.keepalive)
    (cs : List Link.TickIn) (l : Link.Link) (p : Nat) (release : Nat) (rs : List LinkLoop.TickIn) (a : Nat)
    (margin : (c.keepalive + gap) * 1000 + delivery < release)
    (h : Holding delivery gap c cs l p rs a) :
    (LinkLoop.ticks (some release) rs (some a)).2 = [] := by
  have paced := a_held_controller_speaks_often c gap hk cs l p h.held h.spokeBefore.1 h.spokeBefore.2
    h.controllerTicks h.linkAlive
  have later : ∀ (q : Nat) (xs : List LinkLoop.TickIn), Increasing q (xs.map (·.now)) → ∀ j ∈ xs, q < j.now := by
    intro q xs
    induction xs generalizing q with
    | nil => intro _ j hj; simp at hj
    | cons x xs ihx =>
      intro h j hj
      simp only [List.map_cons, Increasing] at h
      rcases List.mem_cons.mp hj with rfl | hj
      · exact h.1
      · have := ihx x.now h.2 j hj; omega
  refine a_spoken_to_robot_never_cuts release (by omega) rs a (l.lastSent * 1000 + delivery)
    h.robotHeardTheLast.2 h.robotTicks h.noNewCentralNoAudio ?_
  intro i hi
  have hlow := later _ rs h.robotTicks i hi
  obtain ⟨s, hs, h1, h2⟩ := somebody_spoke_recently (c.keepalive + gap) delivery (Link.ticks c cs l).2
    l.lastSent i.now paced (by omega) (h.whileTicking i hi)
  rcases List.mem_cons.mp hs with rfl | hs
  · exact ⟨a, Or.inl (by omega), by have := h.robotHeardTheLast; omega, by have := h.robotHeardTheLast; omega⟩
  · obtain ⟨f, hf1, hf2, hsrc⟩ := h.everythingSentIsHeard s hs
    exact ⟨f, hsrc, by omega, by omega⟩

def heldLink : Link.Link := ⟨.held, 5000, 5000, 0, 0, 1⟩

def oneKeepalive : List Link.TickIn := [⟨6000, true, false, .empty⟩]

theorem quietness_happens : Quietness 10000 20000 25000000 5000000 ⟨some 10000, 1000⟩ oneKeepalive heldLink 15000000
    [⟨6010000, .none, true, none⟩, ⟨31000000, .none, false, none⟩] 5010000 where
  lastActionAt := by decide
  noFurtherAction := by simp [oneKeepalive]
  robotTicks := by simp [Paced]
  robotHeardTheAction := by decide
  noNewCentralNoAudio := by simp
  everythingHeardWasSent := by
    intro i hi ht
    simp only [List.mem_cons, List.not_mem_nil, or_false] at hi
    rcases hi with rfl | rfl
    · exact Or.inr ⟨6000, by decide, by decide⟩
    · exact absurd ht (by decide)
  robotStaysUp := ⟨⟨31000000, .none, false, none⟩, by simp, by decide⟩

theorem holding_happens : Holding 20000 1000 ⟨some 10000, 1000⟩ oneKeepalive heldLink 5000
    [⟨6010000, .none, true, none⟩] 5010000 where
  held := rfl
  spokeBefore := by decide
  controllerTicks := by simp [Paced, oneKeepalive]
  linkAlive := by simp [oneKeepalive, heldLink]
  robotHeardTheLast := by decide
  robotTicks := by simp [Increasing, heldLink]
  noNewCentralNoAudio := by simp
  everythingSentIsHeard := by
    intro s hs
    have : s = 6000 := by
      have e : (Link.ticks ⟨some 10000, 1000⟩ oneKeepalive heldLink).2 = [6000] := by decide
      rw [e] at hs
      simpa using hs
    subst this
    exact ⟨6010000, by decide, by decide, Or.inr ⟨⟨6010000, .none, true, none⟩, by simp, rfl, rfl⟩⟩
  whileTicking := by
    intro i hi
    simp only [List.mem_singleton] at hi
    subst hi
    decide

end Theorems.HandOff
