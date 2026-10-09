---
name: stackchan-apple-simulator
description: The "I changed apps/ios, apps/watchos, the controller gem or a darwin build_config, does the app still build and start?" check — cross-build the VM with rake, then build, start in a Simulator with batch arguments and read the console through Xcode MCP.
---

Needs Xcode 27 or later with the MCP server enabled once (`sudo xcrun mcp-server enable`); `.mcp.json` connects it as `xcode`. No robot and no signing certificate.

rake makes the PicoRuby VM and the Xcode project; Xcode MCP does everything Xcode does. `<platform>` is `ios` or `watchos`.

1. `bundle exec rake <platform>:lib <platform>:gen` — `libmruby.a` for the Simulator under `apps/<platform>/Vendor`, and the project (`apps/ios/Stackchan.xcodeproj`, `apps/watchos/WatchStackchan.xcodeproj`). Log to `/tmp/stackchan-picoruby-debug/` and report the exit status of `rake` itself.
2. `XcodeOpenWorkspace` on the project. Approval starts here; the other tools fail before it. Keep the `workspaceIdentifier` it returns.
3. `BuildProject`. A failure comes back as structured errors; fix those, not the log.
4. `DeviceInteractionStartWorkspaceSession` → `DeviceInteractionInstallAndRun` with `commandLineArguments` `["-StackchanBatch", "actions"]` → `GetConsoleOutput` until the line `[batch] end` → `DeviceInteractionEndSession`.
5. `XcodeCloseWorkspace` before the next `<platform>:gen`. Regenerating a project Xcode holds open leaves it with no scheme.

Pass: the console shows one `[batch] <name><TAB><label>` line per action and then `[batch] end`. Other batches (`"connect;status"`) need the robot and belong to `acceptance:darwin`.

- `<platform>:lib` and `<platform>:device:lib` write the same `Vendor/lib/libmruby.a`. After a device build, run `<platform>:lib` again before a Simulator build; a wrong-arch archive still reports `BUILD SUCCEEDED` and the app dies in dyld at start. `lipo -info apps/<platform>/Vendor/lib/libmruby.a` shows which one is there.
- A `rake <platform>:lib` failure is a VM build failure (a gem, a build_config, the picoruby under `vendor/R2P2-darwin`), not an Xcode one.
- A physical iPhone or Watch needs a valid signing certificate and is not part of this check.
