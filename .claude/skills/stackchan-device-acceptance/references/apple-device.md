# Apple Physical Device (`rake acceptance:darwin` / `devicectl`) Constraints

- **Preconditions**: iPhone must already be unlocked and the robot powered on before starting. A locked iPhone refuses launch (`the device was not, or could not be, unlocked`). Unlocking cannot be automated from Mac, and the app intentionally does not keep the screen awake.
- **Command**:
  ```sh
  DEVELOPMENT_TEAM=<team> bundle exec rake acceptance:darwin
  ```
- **Build artifacts**: every run regenerates VM libraries, Xcode projects (`apps/*/*.xcodeproj`), and `apps/*/Vendor` for both iOS and watchOS (watchOS builds even without a Watch present).
- **Timeout & stuck app cleanup**: the iPhone batch stage aborts after `Runner::APP_BATCH_LIMIT_S` (120 s). Because `devicectl ... launch --console` waits for process exit, an iPhone that locks mid-run suspends the app and stalls its internal timeouts. If aborted, the app may still hold the robot over BLE — inspect and kill it:
  ```sh
  xcrun devicectl device info processes --device <UDID>
  xcrun devicectl device process terminate --device <UDID> --pid <pid> --kill
  ```
- **Report rollback**: a failed darwin run rewrites the latest report's verdict to `fail`. If the robot was not at fault, restore the committed report with `git checkout acceptance/results/`.
- **Apple Watch limitations**:
  - Cannot be driven unattended from Mac: an asleep watch never brings the app active, rejects `WKExtendedRuntimeSession` (`The app must be active and before applicationWillResignActive`), and scans 34–60 s finding nothing. Worn and tapped manually, the same app connects immediately. Since iOS and watchOS share one BLE central implementation, iPhone covers physical verification and `stackchan-apple-simulator` covers watchOS batch verification.
  - Watch is visible to Mac only while unlocked, awake, and nearby; leaving range marks it `unavailable` within seconds.
  - `xcrun devicectl device install app` to Watch fails while the Mac screen is locked (`The device is not able to fulfill the requested usage assertion requirements`). Unlock Mac first.
  - A Watch that previously saw an older robot GATT table caches it (`dRuby pair not found; discovered services=1 characteristics=6e400002,6e400003`); reboot the Watch to clear the cache.
- **Observing a manually tapped app's console**:
  ```sh
  xcrun devicectl device process launch --console --terminate-existing --device <UDID> <bundle-id>
  ```
