# CoreS3 App Operation Error Signatures

| Output / Symptom | Cause & Next Action |
|---|---|
| `DONE_ACK ok` | Upload succeeded. |
| `/home/app.mrb started but never returned` | Autostart payload never hands control back to shell. `upload_appmrb` wipes storage first; if seen on `upload_mrb` (`DST=`), run `wipe` → helper upload → autostart upload → `reset`. |
| `does not exist` / `did not come back within` / `[espport]` error | Run `bundle exec rake r2p2:boards`. Ask the owner to replug USB only when the CoreS3 serial is missing from that list. |
| `no shell banner and no boot log` | USB enumerated but silent; check cable or power. |
| `picorbc compilation failed` | Syntax error in `SRC`; fix source before re-uploading. |
| `[monitor guard] idf_monitor.py is running` | Another monitor holds the serial port; detach (`Ctrl+]`) and retry. |
| `face-verify` host golden FAIL | Geometry drift; only run `rake face:register_golden FACE=$FACE` when the visual change is intended. |
| `face-verify` host PASS, device FAIL | Stale payload on device; run `deploy` then re-verify. |
| `ble-smoke` non-zero exit | Connect, GATT discovery, write, or ACK failure. Verify no serial monitor is open and `sudo pkill bluetoothd` if Mac cache is stale. |
| `Guru Meditation Error` / `Rebooting...` | Repeating panic is a debugging task, not another deploy iteration. Run `stackchan-device-diagnose` (`crash-analyze`), then reproduce under `r2p2:qemu_check` or host tests. |
