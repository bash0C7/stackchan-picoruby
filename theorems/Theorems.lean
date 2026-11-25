import Lean
import Theorems.Link
import Theorems.LinkLoop
import Theorems.HandOff
import Theorems.Frame
import Theorems.Contract
import Theorems.Face
import Theorems.Remote
import Theorems.Touch
import Theorems.Conformance
import Theorems.Goals
import Theorems.Oracle

open Lean Elab Command

def standardAxioms : List Name := [``propext, ``Quot.sound, ``Classical.choice]

def ours (env : Environment) (name : Name) : Bool :=
  match env.getModuleIdxFor? name with
  | some i => (`Theorems).isPrefixOf env.header.moduleNames[i.toNat]!
  | none => false

elab "#every_theorem_rests_on_standard_axioms_and_guards_a_failure" : command => do
  let env ← getEnv
  let mut written : Array Name := #[]
  let mut broken := 0
  for (name, info) in env.constants.map₁.toList do
    if ours env name && info matches ConstantInfo.thmInfo _ then
      for ax in ← collectAxioms name do
        unless standardAxioms.contains ax do
          broken := broken + 1
          logError m!"{name} rests on {ax}"
      if (← findDeclarationRanges? name).isSome && !name.isInternalDetail && !(env.isProjectionFn name) then
        written := written.push name
  let mut used : NameSet := {}
  let mut todo : List Name := Theorems.Oracle.failures.flatMap (·.guards)
  while !todo.isEmpty do
    let name := todo.head!
    todo := todo.tail!
    unless used.contains name do
      used := used.insert name
      if let some info := env.find? name then
        for c in info.getUsedConstantsAsSet.toList do
          if ours env c then todo := c :: todo
  for f in Theorems.Oracle.failures do
    if f.guards.isEmpty then
      broken := broken + 1
      logError m!"no theorem guards: {f.what}"
  for name in written do
    unless used.contains name do
      broken := broken + 1
      logError m!"{name} guards no failure in Theorems.Oracle.failures"
  if written.isEmpty then
    logError "no theorem was checked"
  else if broken == 0 then
    logInfo m!"{written.size} theorems guard {Theorems.Oracle.failures.length} failures and rest only on {standardAxioms}"

#every_theorem_rests_on_standard_axioms_and_guards_a_failure
