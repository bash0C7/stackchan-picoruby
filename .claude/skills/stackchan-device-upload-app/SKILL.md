---
name: stackchan-device-upload-app
description: Host-compile a .rb to .mrb and upload it over PicoModem (~7 s). Default target is the autostart payload /home/app.mrb; DST= uploads a non-autostart helper instead.
---

Run in a haiku subagent (120000ms timeout), reporting exit code and the `DONE_ACK` line:

    bundle exec rake r2p2:upload_appmrb SRC=$SRC 2>&1 | tee /tmp/stackchan-picoruby-debug/upload-app.log
    # helper under /home/lib etc.:
    bundle exec rake r2p2:upload_mrb SRC=$SRC DST=/home/lib/helper.mrb

The task resets the board and waits for the shell banner itself; no settle time or USB replug needed.

- `DONE_ACK ok` = uploaded.
- `/home/app.mrb started but never returned` = the payload already on the device never hands control back. Retrying is pointless; run `stackchan-device-cold-recovery`.
- `does not exist` / `did not come back within` = board not on USB; human replug.
- `no shell banner and no boot log` = enumerated but silent; cable or power.
- `picorbc compilation failed` = syntax error in SRC.
- `[monitor guard]` = Ctrl+] the open monitor, retry.
