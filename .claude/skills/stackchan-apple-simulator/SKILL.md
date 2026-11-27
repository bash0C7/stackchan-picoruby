---
name: stackchan-apple-simulator
description: Cross-build the iOS or watchOS PicoRuby VM with rake, then build and run the app in Simulator with -StackchanBatch "actions;status" via Xcode MCP. Use after changing apps/ios, apps/watchos, picoruby-stackchan-controller, or darwin build_config.
argument-hint: "<ios|watchos>"
effort: medium
---

# Apple Simulator Batch Verification

Verify that `apps/<platform>` (`ios` or `watchos`, from `$ARGUMENTS`) builds and runs its controller inside the real Darwin PicoRuby VM without a robot or signing certificate.

## Prerequisites

- Xcode running with `.mcp.json`'s `xcode` server approved for this project (`mcp__xcode__*` tools appear only in a session started after approval).
- Ensure Xcode's `/usr/bin/swift` precedes `~/.swiftly/bin` in `PATH` (Swiftly's `swift` fails with `unknown argument: '-target-arch-variant'`).

## Procedure

1. **Build VM & generate Xcode project**:
   ```sh
   mkdir -p /tmp/stackchan-picoruby-debug
   set -o pipefail
   PATH="/usr/bin:$PATH" bundle exec rake <platform>:lib <platform>:gen 2>&1 | tee /tmp/stackchan-picoruby-debug/<platform>-sim-gen.log
   ```
   - Produces Simulator `libmruby.a` under `apps/<platform>/Vendor` and `apps/ios/Stackchan.xcodeproj` or `apps/watchos/WatchStackchan.xcodeproj`.
   - Failure here is a VM/gem/`build_config`/`vendor/R2P2-darwin` failure, not an Xcode failure.
   - `<platform>:lib` and `<platform>:device:lib` overwrite the same `Vendor/lib/libmruby.a`. After any device build, re-run `<platform>:lib` before a Simulator build (wrong-arch archive still reports `BUILD SUCCEEDED` and crashes in `dyld`).
2. **Open workspace**: call `XcodeOpenWorkspace` with the absolute `.xcodeproj` path. Save `workspaceIdentifier`. Confirm `activeRunDestination` is a Simulator; if it points to a physical device, call `XcodeListRunDestinations` and `XcodeSwitchRunDestination` to a Simulator `displayTitle`.
3. **Build**: call `BuildProject`. Success is `errors: []`. Fix structured errors directly. Exception: if Xcode reports `module file '…/DerivedData/SDKExplicitPrecompiledModules/….pcm' not found` after a clean shared module cache, invoke `BuildProject` once more.
4. **Boot Simulator session**: call `DeviceInteractionStartWorkspaceSession` with a chosen `sessionIdentifier` to get `interactionSessionKey`. Skip any UI-interaction subagent suggestion (no UI events are sent).
5. **Install & run batch**: call `DeviceInteractionInstallAndRun` with `interactionSessionKey` and `commandLineArguments: ["-StackchanBatch", "actions;status"]`.
6. **Read console**: call `GetConsoleOutput` with `pattern: "\\[batch\\]|Error"`.
   - Batch output appears as `kind: stdio`; bridge logs (`VM opened`, `actions() ->`) appear as `kind: oslog`.
   - Empty result immediately after launch means the app has not printed yet — query again. `State: expired` indicates normal batch exit.
7. **Clean up**: call `DeviceInteractionEndSession`, then `XcodeCloseWorkspace` before any future `<platform>:gen` (regenerating a project Xcode holds open leaves it without a scheme).

## Pass Criteria

Console shows:
1. One `[batch] <name><TAB><label>` line per declared action
2. `[batch] link=released …` (output of `status` — the first call that instantiates the BLE central inside the Darwin VM, catching missing language-extension gems such as `mruby-hash-ext`/`mruby-numeric-ext`/`mruby-method` that produce `[batch] vm_call:1: undefined method …`)
3. `[batch] end`

Do not run `rake ios:run` or `rake ios:all` (they block on `open -a Simulator`). Batches reaching a physical robot (`"connect;joy"`) belong to `/stackchan-device-acceptance` (`darwin`).
