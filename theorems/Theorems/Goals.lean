import Theorems.Conformance
import Theorems.Facts.Apps

namespace Theorems.Goals

open Theorems

def declares_both (app : Facts.Apps.App) : Bool :=
  app.hold.isSome && match Facts.Apps.releaseAfter with
    | some release => 0 < release
    | none => false

def holds_on (app : Facts.Apps.App) : Bool :=
  match Facts.Apps.releaseAfter with
  | some release => Facts.Link.keepalive + app.tickMs + Facts.Apps.ackTimeoutMs < release
  | none => false

theorem the_controllers_are_the_mac_the_iphone_and_the_watch :
    Facts.Apps.controllers.map (·.name) = ["mac", "ios", "watchos"] := by decide +kernel

theorem every_controller_lets_go_and_the_robot_cuts_silence :
    Facts.Apps.controllers.all declares_both = true := by decide +kernel

theorem every_controller_outpaces_the_robot :
    (0 < Facts.Link.keepalive && Facts.Apps.controllers.all holds_on) = true := by decide +kernel

theorem every_controller_hands_the_robot_over (app : Facts.Apps.App) (known : app ∈ Facts.Apps.controllers)
    (hold release : Nat) (hh : app.hold = some hold) (hr : Facts.Apps.releaseAfter = some release)
    (delivery gap t₀ : Nat) (cs : List Link.TickIn) (l : Link.Link) (rs : List LinkLoop.TickIn) (a : Nat)
    (q : HandOff.Quietness hold delivery gap t₀ ⟨app.hold, Facts.Link.keepalive⟩ cs l (release * 1000) rs a) :
    ∃ t, HandOff.letGo (some (release * 1000)) rs (some a) t ∧
      t < t₀ + hold * 1000 + delivery + release * 1000 + gap := by
  have b := List.all_eq_true.mp every_controller_lets_go_and_the_robot_cuts_silence app known
  simp only [declares_both, hr, Bool.and_eq_true, decide_eq_true_eq] at b
  exact HandOff.the_robot_is_handed_over hold delivery gap t₀ ⟨app.hold, Facts.Link.keepalive⟩ hh cs l
    (release * 1000) (by have := b.2; omega) rs a q

theorem every_controller_keeps_the_robot_while_holding (app : Facts.Apps.App) (known : app ∈ Facts.Apps.controllers)
    (release : Nat) (hr : Facts.Apps.releaseAfter = some release) (delivery : Nat)
    (prompt : delivery ≤ Facts.Apps.ackTimeoutMs * 1000) (cs : List Link.TickIn) (l : Link.Link) (p : Nat)
    (rs : List LinkLoop.TickIn) (a : Nat)
    (h : HandOff.Holding delivery app.tickMs ⟨app.hold, Facts.Link.keepalive⟩ cs l p rs a) :
    (LinkLoop.ticks (some (release * 1000)) rs (some a)).2 = [] := by
  have paces := every_controller_outpaces_the_robot
  simp only [Bool.and_eq_true, decide_eq_true_eq, List.all_eq_true] at paces
  have m := paces.2 app known
  simp only [holds_on, hr, decide_eq_true_eq] at m
  exact HandOff.a_holding_controller_is_never_cut delivery app.tickMs ⟨app.hold, Facts.Link.keepalive⟩ paces.1 cs l p
    (release * 1000) rs a (by simp only; omega) h

theorem a_robot_left_alone_after_cold_boot_never_opens_its_eyes (es : List Face.FaceEvent) (h : es.all Face.idle = true)
    (w : Bool) : (Face.run Facts.Face.faces ⟨Facts.Face.coldBoot, w⟩ es).1.face = "closed" ∧
      (Face.run Facts.Face.faces ⟨Facts.Face.coldBoot, w⟩ es).2 = false := by
  obtain ⟨boot, shut⟩ := Conformance.the_robot_wakes_with_its_eyes_closed
  rw [boot]
  exact Face.an_idle_robot_keeps_its_eyes_closed _ shut es h w

def assumptions : List (String × String) := [
  ("HandOff.Quietness.robotTicks", "release and reconnect"),
  ("HandOff.Quietness.robotHeardTheAction", "release and reconnect"),
  ("HandOff.Quietness.everythingHeardWasSent", "release and reconnect"),
  ("HandOff.Quietness.robotStaysUp", "release and reconnect"),
  ("HandOff.Holding.controllerTicks", "touch listen"),
  ("HandOff.Holding.everythingSentIsHeard", "touch listen"),
  ("HandOff.Holding.robotTicks", "touch listen")
]

theorem every_assumption_has_a_step_that_looks_at_it :
    assumptions.all (fun (_, step) => Facts.Apps.acceptanceSteps.contains step) = true := by decide +kernel

end Theorems.Goals
