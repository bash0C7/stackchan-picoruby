# pc/stackchan-pico

The launchd and process glue of the Mac side. How the Mac side is built,
started and used is in the top-level [README](../../README.md#macos-side).

| File | What it is |
|---|---|
| `bin/stackchan` | The CLI. Runs `app/boot_cli.rb` on the Mac VM with the verb and its arguments. Env: `STACKCHAN_PICORUBY` (VM path, default `vendor/R2P2-darwin/build/host/bin/picoruby`), `STACKCHAN_ROOT` (repo root), `STACKCHAN_PORT` (daemon port, default 8787). |
| `app/boot_cli.rb` | Loads the controller gem's `cli.rb` and `calibration.rb` from source and runs `StackChan::Controller::CLI` against the daemon. Arguments: root, port, then the verb and its arguments. |
| `app/boot_daemon.rb` | The daemon launchd starts from the app bundle. Loads the protocol gem, picoruby-drb-ble, the controller gem and `apps/mac/app.rb` from source and calls `App.serve`. Arguments: root, port, name prefix (`fake` loads `app/fake_ble.rb` instead of the BLE radio), sidecar port. |
| `app/fake_ble.rb` | `FakeBleClient`, the radio `BLE_FAKE=1` swaps in. It answers frames and `remote` calls without hardware and has no audio path, so `say`, `demo` and a speaking `chat` stop with an error. |
| `app/drb_eintr_retry.rb` | Retries a socket read that fails with "read failed" up to 3 times, and a DRb connect interrupted by a signal up to 5 times. The daemon, the CLI and the sidecar load it. |
| `StackchanPico-Info.plist` | The app bundle's `Info.plist` (`com.bash0c7.stackchanpico`, the Bluetooth usage strings). `rake pc:app_bundle` copies it in. |
