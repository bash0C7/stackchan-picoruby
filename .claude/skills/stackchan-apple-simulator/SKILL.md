---
name: stackchan-apple-simulator
description: The "I changed apps/ios, apps/watchos, the controller gem or a darwin build_config, does the app still build and start?" check — cross-build the VM with rake, then build, start in a Simulator with batch arguments and read the console through Xcode MCP.
---

Needs Xcode running, and the `xcode` server of `.mcp.json` approved for this project (Claude Code asks at start; `claude mcp list` shows `Pending approval` until then, and the `mcp__xcode__*` tools exist only in a session started after the approval). No robot and no signing certificate.

rake makes the PicoRuby VM and the Xcode project; Xcode MCP does everything Xcode does. `<platform>` is `ios` or `watchos`.

1. `bundle exec rake <platform>:lib <platform>:gen` — `libmruby.a` for the Simulator under `apps/<platform>/Vendor`, and the project (`apps/ios/Stackchan.xcodeproj`, `apps/watchos/WatchStackchan.xcodeproj`). Log to `/tmp/stackchan-picoruby-debug/` and report the exit status of `rake` itself.
2. `XcodeOpenWorkspace` with `path` = the absolute path of the `.xcodeproj`. It returns `workspaceIdentifier` (pass it to every later call), `activeScheme` and `activeRunDestination`. The destination Xcode picks is a Simulator; if it names a physical device, `XcodeListRunDestinations` and `XcodeSwitchRunDestination` with a Simulator's `displayTitle`.
3. `BuildProject`. Success is `errors: []`. A failure comes back as structured errors; fix those, not the log. One failure is Xcode's, not the project's: `module file '…/DerivedData/SDKExplicitPrecompiledModules/….pcm' not found` on the first build after Xcode's shared module cache was emptied — run `BuildProject` once more.
4. `DeviceInteractionStartWorkspaceSession` with a `sessionIdentifier` of your choosing; it boots the Simulator and returns `interactionSessionKey`. Its reply tells you to spawn a subagent for UI interaction; this check sends no UI event, so skip that.
5. `DeviceInteractionInstallAndRun` with that `interactionSessionKey` and `commandLineArguments` `["-StackchanBatch", "actions"]`.
6. `GetConsoleOutput` with `pattern` `\[batch\]|Error`. The batch lines are the units of `kind: stdio`; the bridge's own log (`VM opened`, `actions() ->`) is `kind: oslog`. An empty result right after the launch means the app has not printed yet: ask again. The session reads `State: expired` once the app has exited, which is how a finished batch looks.
7. `DeviceInteractionEndSession`, then `XcodeCloseWorkspace` before the next `<platform>:gen`. Regenerating a project Xcode holds open leaves it with no scheme.

Pass: the console shows one `[batch] <name><TAB><label>` line per action and then `[batch] end`. Other batches (`"connect;status"`) need the robot and belong to `acceptance:darwin`.

- `<platform>:lib` and `<platform>:device:lib` write the same `Vendor/lib/libmruby.a`. After a device build, run `<platform>:lib` again before a Simulator build; a wrong-arch archive still reports `BUILD SUCCEEDED` and the app dies in dyld at start.
- A `rake <platform>:lib` failure is a VM build failure (a gem, a build_config, the picoruby under `vendor/R2P2-darwin`), not an Xcode one.
- A physical iPhone or Watch needs a valid signing certificate and is not part of this check.
