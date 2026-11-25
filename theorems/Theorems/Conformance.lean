import Theorems.HandOff
import Theorems.Facts.Link
import Theorems.Facts.LinkLoop
import Theorems.Facts.Apps
import Theorems.Facts.Frame
import Theorems.Facts.Contract
import Theorems.Facts.Face
import Theorems.Facts.Remote
import Theorems.Facts.Touch

namespace Theorems.Conformance

open Theorems

def sameSet (xs ys : List String) : Bool :=
  xs.all ys.contains && ys.all xs.contains

def allBools : List Bool := [true, false]

def allStates : List Link.State := [.released, .held, .quiet, .busy]

def allReplies : List Link.Keepalive := [.empty, .zone, .connectionError, .timeout, .timeoutLost]

def allConnects : List Link.Connect := [.ok, .refused, .mismatch]

def allBodies : List Link.Body := [.ok, .connectionError, .timeout, .timeoutLost, .otherError, .okLost]

def allPackets : List LinkLoop.Packet := [.none, .arrived, .disconnected, .working, .notWorking, .other, .notAString]

def edges (limit : Nat) : List Nat := [0, limit - 1, limit, limit + 1]

theorem the_link_ticks_as_modeled :
    Facts.Link.observedTicks.all (fun (hold, i, before, after, calls, _) =>
      Link.tick ⟨hold, Facts.Link.keepalive⟩ i before == (after, calls)) = true := by decide +kernel

theorem the_link_acts_as_modeled :
    Facts.Link.observedActs.all (fun (i, before, out, _) => Link.act i before == out) = true := by decide +kernel

theorem every_release_tells_the_daemon_once :
    (Facts.Link.observedTicks.all (fun (_, _, before, after, _, lost) => lost == after.releases - before.releases) &&
      Facts.Link.observedActs.all (fun (_, before, out, lost, _) => lost == out.link.releases - before.releases)) = true := by
  decide +kernel

theorem an_action_returns_what_its_body_returned :
    Facts.Link.observedActs.all (fun (_, _, out, _, passes, _) => out.result != .ok || passes) = true := by decide +kernel

theorem the_generation_counts_the_connects :
    Facts.Link.observedActs.all (fun (_, _, out, _, _, generation, _) => generation == out.link.connects) = true := by
  decide +kernel

theorem a_connect_records_how_long_it_took :
    Facts.Link.observedActs.all (fun (_, _, out, _, _, _, took) =>
      took == if Link.connectedNow out then some 0 else none) = true := by decide +kernel

theorem listening_extends_only_a_held_link :
    Facts.Link.observedListens.all (fun (before, after) => after == Link.listen 100000 before) = true := by decide +kernel

theorem a_new_link_is_released_and_empty :
    Facts.Link.fresh = "link=released connects=0 releases=0 last_connect_ms=none hold_ms=10000 touches=0" := by
  decide +kernel

theorem the_robot_loop_ticks_as_modeled :
    Facts.LinkLoop.observedTicks.all (fun (release, i, before, after, cuts, advertised, resets, waits, popped, ticked) =>
      (after, cuts) == ((LinkLoop.tick release i before).1, if (LinkLoop.tick release i before).2 then 1 else 0) &&
      advertised == LinkLoop.advertises i.packet && resets == LinkLoop.drbResets i.packet &&
      waits == [Facts.LinkLoop.tickMs] && popped == 1 && ticked == [i.now / 1000]) = true := by
  decide +kernel

theorem every_link_tick_class_is_observed :
    Facts.Link.observedTicks.map (fun (hold, i, before, _) =>
        ((hold, before.state, i.now - before.lastAction, i.now - before.lastSent),
          (before.touches, i.drainLoses, i.expire, i.reply))) =
      [some 10000, none].flatMap fun hold => allStates.flatMap fun state => (edges (hold.getD 10000)).flatMap fun actionAge =>
        (edges Facts.Link.keepalive).flatMap fun sentAge => [0, 1].flatMap fun touches => [false, true].flatMap fun drain =>
          allBools.flatMap fun expire => allReplies.map fun reply =>
            ((hold, state, actionAge, sentAge), (touches, drain, expire, reply)) := by decide +kernel

theorem every_link_action_class_is_observed :
    Facts.Link.observedActs.map (fun (i, before, _) => (before.state, before.touches, i.drainLoses, i.connect, i.body)) =
      allStates.flatMap fun state => [0, 1].flatMap fun touches => [false, true].flatMap fun drain =>
        allConnects.flatMap fun connect => allBodies.map fun body => (state, touches, drain, connect, body) := by decide +kernel

theorem every_robot_tick_class_is_observed :
    [Facts.Apps.releaseAfter.map (· * 1000), none].all (fun release => (none :: (edges (release.getD 15000000)).map some).all fun age =>
      allPackets.all fun packet => allBools.all fun traffic => allBools.all fun played =>
        Facts.LinkLoop.observedTicks.any fun (r, i, before, _) =>
          r == release && before.map (i.now - ·) == age && i.packet == packet && i.traffic == traffic &&
            i.played.isSome == played) = true := by decide +kernel

theorem the_link_keeps_no_state_the_model_lacks :
    sameSet Facts.Link.state ["@central", "@clock", "@hold", "@keepalive_ms", "@log", "@on_lost", "@last_connect_ms",
      "@state", "@last_action_at", "@last_sent_at", "@touches", "@releases", "@connects"] = true := by decide +kernel

theorem the_robot_loop_keeps_no_state_the_model_lacks :
    sameSet Facts.LinkLoop.state ["@port", "@ticker", "@on_packet", "@clock", "@drb", "@remote", "@release_after_us",
      "@active_at"] = true := by decide +kernel

theorem every_app_frame_class_is_tried :
    Facts.Frame.observedApp.map (·.1) = Frame.appFrames := by decide +kernel

theorem every_handler_frame_class_is_tried :
    Facts.Frame.observedHandlers.map (·.1) = Frame.handlerFrames := by decide +kernel

theorem the_robot_answers_frames_as_specified :
    Facts.Frame.observedApp.all (fun (f, o) => o == Frame.spec Facts.Frame.appTables f) = true := by decide +kernel

theorem the_robot_runs_app_handlers_as_specified :
    Facts.Frame.observedHandlers.all (fun (f, o) => o == Frame.spec Facts.Frame.handlerTables f) = true := by
  decide +kernel

theorem the_head_moves_by_the_normalized_formula :
    (Facts.Frame.observedHead.map (·.1) = List.range 101 ∧
      Facts.Frame.observedHead.all (fun (m, l, r, p) =>
        l == Frame.yawLeft m && r == Frame.yawRight m && p == Frame.pitchUp m) = true) := by
  decide +kernel

theorem the_robot_vocabulary_is_the_specified_one :
    Facts.Contract.engineKeys = Frame.frameKeys ∧ Facts.Contract.systemKeys = Frame.systemKeys := by decide +kernel

def allGateEvents : List Contract.GateEvent := [.helloOurs, .helloTheirs, .call, .reset, .garbage]

theorem every_gate_class_is_observed :
    Facts.Contract.observedGate.map (fun (o, e, _) => (o, e)) =
      [false, true].flatMap fun o => allGateEvents.map (o, ·) := by decide +kernel

theorem the_gate_opens_as_modeled :
    Facts.Contract.observedGate.all (fun (o, e, answered, after) => Contract.gateStep o e == (answered, after)) = true := by
  decide +kernel

theorem the_gate_keeps_no_state_the_model_lacks :
    sameSet Facts.Contract.gateState ["@front", "@allow", "@gate", "@open", "@buf", "@fields", "@taken"] = true := by
  decide +kernel

theorem the_robot_takes_a_hello_as_its_own_exactly_when_the_text_is_its_contract :
    Facts.Contract.helloAnswers.all (fun (text, ours) => ours == (text == Facts.Contract.robot)) = true ∧
      Facts.Contract.helloAnswers.any (·.2) = true ∧ Facts.Contract.helloAnswers.any (!·.2) = true := by decide +kernel

theorem the_robot_and_the_controllers_carry_the_same_contract :
    Facts.Contract.controller = Facts.Contract.robot := by decide +kernel

theorem a_controller_goes_on_only_with_a_robot_of_its_contract :
    Facts.Contract.agreements.map (·.1) = ["same", "different", "none"] ∧
      Facts.Contract.agreements.all (fun (robot, result, connected) =>
        (result == "ok") == (robot == "same") && connected == (result == "ok")) = true := by decide +kernel

def rawPositions : List (Option Nat) := [none, some 0, some 482, some 1023]

def rawPitches : List (Option Nat) := [none, some 0, some 633, some 1023]

theorem the_controller_reads_back_the_raw_pose_the_robot_reports :
    Facts.Contract.readings.map (fun (y, p, _) => (y, p)) = rawPositions.flatMap (fun y => rawPitches.map (y, ·)) ∧
      Facts.Contract.readings.all (fun (y, p, y', p') => y' == y && p' == p) = true := by decide +kernel

theorem every_named_front_call_answers_as_its_frame :
    Facts.Remote.aliases.map (·.1) = ["face 1", "face 9", "text", "torque true", "torque on", "torque false", "torque off",
      "read_pos", "selftest", "servo", "led"] ∧
      Facts.Remote.aliases.all (fun (_, called, direct) => called == direct) = true := by decide +kernel

theorem the_contract_names_the_robot_vocabulary :
    sameSet Facts.Contract.contractKeys (Facts.Contract.engineKeys ++ Facts.Contract.systemKeys) = true := by
  decide +kernel

theorem every_frame_a_controller_sends_is_accepted :
    Facts.Contract.sent.all (fun (_, _, _, _, reply) => reply == ".") = true := by decide +kernel

theorem every_key_a_controller_sends_is_in_the_contract :
    Facts.Contract.sent.all (fun (_, _, _, keys, _) => keys.all Facts.Contract.contractKeys.contains) = true := by
  decide +kernel

theorem every_contract_key_is_sent_by_some_controller :
    Facts.Contract.contractKeys.all (fun k => Facts.Contract.sent.any fun (_, _, _, keys, _) => keys.contains k) = true := by
  decide +kernel

theorem every_declared_action_sends_a_frame :
    Facts.Contract.actions.all (fun (app, action) => Facts.Contract.sent.any fun (a, b, _) => a == app && b == action) =
      true := by decide +kernel

def faceEvents : List Face.FaceEvent :=
  [.close, .reopen, .torqueOn, .torqueOff] ++ Facts.Face.faces.index.map (fun (i, _) => .show i) ++ [.show "9"]

theorem every_face_class_is_observed :
    Facts.Face.observed.map (fun (l, e, _) => (l, e)) =
      Facts.Face.names.flatMap fun n => [false, true].flatMap fun w => faceEvents.map ((⟨n, w⟩ : Face.Look), ·) := by
  decide +kernel

theorem the_face_changes_as_modeled :
    Facts.Face.observed.all (fun (l, e, after, opened) => Face.step Facts.Face.faces l e == (after, opened)) = true := by
  decide +kernel

theorem the_robot_wakes_with_its_eyes_closed :
    Facts.Face.coldBoot = "closed" ∧ Facts.Face.faces.openEyed.contains "closed" = false := by decide +kernel

theorem the_ticker_keeps_no_face_state_the_model_lacks :
    sameSet Facts.Face.tickerState ["@display", "@led", "@touch", "@dispatcher", "@remote", "@touch_handlers",
      "@periodic", "@periodic_due", "@robot_handle", "@now_ms", "@touch_at", "@led_at", "@open_at"] = true := by
  decide +kernel

theorem every_touch_class_is_observed :
    Facts.Touch.observedPolls.map (fun (last, p, _) => (last, p)) =
      [none, some 951, some 950].flatMap fun last => [none, some 0, some 1].flatMap fun z =>
        [false, true].map fun f => (last, (⟨1000, z, f⟩ : Touch.Poll)) := by decide +kernel

theorem the_ticker_reads_touches_as_modeled :
    Facts.Touch.observedPolls.all (fun (last, p, r) => Touch.poll [0] last p == r) = true := by decide +kernel

theorem every_handle_call_class_is_tried :
    Facts.Touch.observedCalls.map (·.1) =
      (Facts.Face.names ++ ["nope"]).map .face ++
        (["left", "right", "both"].flatMap fun s => ["solid", "blink"].flatMap fun m =>
          [none, some 300].map fun f => Touch.Call.led s 1 2 3 m f) ++
        [.head (some 50) none (some 30) 400, .head none (some 60) none 0, .text "hi"] := by decide +kernel

theorem the_handle_does_what_the_app_names :
    Facts.Touch.observedCalls.all (fun (c, effects) => effects == [Touch.effect Facts.Face.names "closed" c]) = true := by
  decide +kernel

def remoteEvents : List Remote.Event := [.touch 1, .take, .begin, .chunk 2, .play, .perform, .done]

theorem every_front_class_is_observed :
    Facts.Remote.observed.map (fun (s, e, _) => (s.touches.length, s.buffered, s.pending, s.finished, e)) =
      [0, 1, 15, 16].flatMap fun q => [0, 3].flatMap fun b => [false, true].flatMap fun p =>
        [false, true].flatMap fun f => remoteEvents.map (q, b, p, f, ·) := by decide +kernel

theorem the_front_answers_as_modeled :
    Facts.Remote.observed.all (fun (s, e, after, out) => Remote.step s e == (after, out)) = true := by decide +kernel

theorem the_front_keeps_no_state_the_model_lacks :
    sameSet Facts.Remote.state ["@dispatcher", "@exposed", "@speaker", "@head", "@touch_queue", "@audio_buf",
      "@audio_pending", "@audio_done", "@contract"] = true := by decide +kernel

end Theorems.Conformance
