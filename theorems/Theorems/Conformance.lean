import Theorems.HandOff
import Theorems.Facts.Link
import Theorems.Facts.LinkLoop
import Theorems.Facts.Apps

namespace Theorems.Conformance

open Theorems

def sameSet (xs ys : List String) : Bool :=
  xs.all ys.contains && ys.all xs.contains

def allBools : List Bool := [true, false]

def allStates : List Link.State := [.released, .held, .quiet, .busy]

def allReplies : List Link.Keepalive := [.empty, .zone, .connectionError, .timeout, .timeoutLost]

def allBodies : List Link.Body := [.ok, .connectionError, .timeout, .timeoutLost, .otherError, .okLost]

def allPackets : List LinkLoop.Packet := [.none, .arrived, .disconnected, .other, .notAString]

def edges (limit : Nat) : List Nat := [0, limit - 1, limit, limit + 1]

theorem the_link_ticks_as_modeled :
    Facts.Link.observedTicks.all (fun (hold, i, before, after, calls) =>
      Link.tick ⟨hold, Facts.Link.keepalive⟩ i before == (after, calls)) = true := by decide +kernel

theorem the_link_acts_as_modeled :
    Facts.Link.observedActs.all (fun (i, before, out) => Link.act i before == out) = true := by decide +kernel

theorem the_robot_loop_ticks_as_modeled :
    Facts.LinkLoop.observedTicks.all (fun (release, i, before, after, cuts) =>
      (after, cuts) == ((LinkLoop.tick release i before).1, if (LinkLoop.tick release i before).2 then 1 else 0)) = true := by
  decide +kernel

theorem every_link_tick_class_is_observed :
    Facts.Link.observedTicks.map (fun (hold, i, before, _, _) =>
        ((hold, before.state, i.now - before.lastAction, i.now - before.lastSent),
          (before.touches, i.drainLoses, i.expire, i.reply))) =
      [some 10000, none].flatMap fun hold => allStates.flatMap fun state => (edges (hold.getD 10000)).flatMap fun actionAge =>
        (edges Facts.Link.keepalive).flatMap fun sentAge => [0, 1].flatMap fun touches => [false, true].flatMap fun drain =>
          allBools.flatMap fun expire => allReplies.map fun reply =>
            ((hold, state, actionAge, sentAge), (touches, drain, expire, reply)) := by decide +kernel

theorem every_link_action_class_is_observed :
    Facts.Link.observedActs.map (fun (i, before, _) => (before.state, before.touches, i.drainLoses, i.connects, i.body)) =
      allStates.flatMap fun state => [0, 1].flatMap fun touches => [false, true].flatMap fun drain =>
        allBools.flatMap fun connects => allBodies.map fun body => (state, touches, drain, connects, body) := by decide +kernel

theorem every_robot_tick_class_is_observed :
    [Facts.Apps.releaseAfter.map (· * 1000), none].all (fun release => (none :: (edges (release.getD 15000000)).map some).all fun age =>
      allPackets.all fun packet => allBools.all fun traffic => allBools.all fun played =>
        Facts.LinkLoop.observedTicks.any fun (r, i, before, _, _) =>
          r == release && before.map (i.now - ·) == age && i.packet == packet && i.traffic == traffic &&
            i.played.isSome == played) = true := by decide +kernel

theorem the_link_keeps_no_state_the_model_lacks :
    sameSet Facts.Link.state ["@central", "@clock", "@hold", "@keepalive_ms", "@log", "@on_lost", "@last_connect_ms",
      "@state", "@last_action_at", "@last_sent_at", "@touches", "@releases", "@connects"] = true := by decide +kernel

theorem the_robot_loop_keeps_no_state_the_model_lacks :
    sameSet Facts.LinkLoop.state ["@port", "@ticker", "@on_packet", "@clock", "@drb", "@remote", "@release_after_us",
      "@active_at"] = true := by decide +kernel

end Theorems.Conformance
