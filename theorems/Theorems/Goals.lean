import Theorems.Conformance
import Theorems.Facts.Apps

namespace Theorems.Goals

open Theorems

def budgetMs : Nat := 25000

def lets_go_in_budget (app : Facts.Apps.App) : Bool :=
  match app.hold, Facts.Apps.releaseAfter with
  | some hold, some release => 0 < release && hold + release ≤ budgetMs
  | _, _ => false

def holds_on (app : Facts.Apps.App) : Bool :=
  match Facts.Apps.releaseAfter with
  | some release => Facts.Link.keepalive + app.tickMs + Facts.Apps.ackTimeoutMs < release
  | none => false

theorem the_controllers_are_the_mac_the_iphone_and_the_watch :
    Facts.Apps.controllers.map (·.name) = ["mac", "ios", "watchos"] := by decide +kernel

theorem every_controller_declares_its_hold_in_budget :
    Facts.Apps.controllers.all lets_go_in_budget = true := by decide +kernel

theorem every_controller_speaks_only_when_asked :
    Facts.Apps.controllers.all (fun app => app.touchHandlers == 0 && app.periodic == 0) = true := by decide +kernel

theorem every_controller_outpaces_the_robot :
    (0 < Facts.Link.keepalive && Facts.Apps.controllers.all holds_on) = true := by decide +kernel

theorem every_controller_hands_the_robot_over (app : Facts.Apps.App) (known : app ∈ Facts.Apps.controllers)
    (hold release : Nat) (hh : app.hold = some hold) (hr : Facts.Apps.releaseAfter = some release)
    (delivery gap t₀ : Nat) (cs : List Link.TickIn) (l : Link.Link) (rs : List LinkLoop.TickIn) (a : Nat)
    (q : HandOff.Quietness hold delivery gap t₀ ⟨app.hold, Facts.Link.keepalive⟩ cs l (release * 1000) rs a) :
    ∃ t, HandOff.letGo (some (release * 1000)) rs (some a) t ∧ t < t₀ + budgetMs * 1000 + delivery + gap := by
  have b := List.all_eq_true.mp every_controller_declares_its_hold_in_budget app known
  simp only [lets_go_in_budget, hh, hr, Bool.and_eq_true, decide_eq_true_eq] at b
  obtain ⟨t, ht, hlt⟩ := HandOff.the_robot_is_handed_over hold delivery gap t₀ ⟨app.hold, Facts.Link.keepalive⟩ hh cs l
    (release * 1000) (by omega) rs a q
  have fits : hold + release ≤ 25000 := b.2
  refine ⟨t, ht, ?_⟩
  simp only [budgetMs]
  clear q ht b
  omega

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
