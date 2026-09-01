---
name: stackchan-device-iterate
description: The standard "I changed application.rb, did it work?" loop — upload, reset, capture boot, analyze any panic (~50 s).
---

1. `stackchan-device-upload-app` with `SRC=app/application.rb` (or the given SRC)
2. `stackchan-device-reset`
3. `stackchan-device-capture-boot` with `SECONDS=25`
4. Panic in the log → `stackchan-device-crash-analyze`

Report: upload ok / reset ok / boot markers found / panic and its analysis. An upload failure goes to `stackchan-device-cold-recovery`; a repeating panic is a debugging task, not another iteration.
