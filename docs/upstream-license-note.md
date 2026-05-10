# Upstream license note

Source: `m5stack/StackChan@f8bbb9084d8410194ea3efd5a78b184ee2e3b6d4` (`firmware/main/hal/board/stackchan_display.cc`)

License found: `SPDX-License-Identifier: MIT` (per-file SPDX header, `SPDX-FileCopyrightText: 2026 M5Stack Technology CO LTD`). The repository has no top-level `LICENSE` / `LICENSE.md` / `COPYING` file as of this commit; the in-file SPDX identifier is the authoritative declaration for this source file.

Reuse decision: **Yes** — pin numbers, register addresses, and ILI9342 initialization byte sequences may be transcribed verbatim from the upstream C++ source into our Pure-Ruby mrbgem `picoruby-ili9342`. Rationale:

- MIT is a permissive license that explicitly permits use, copy, modify, merge, publish, distribute, sublicense, and sale of copies of the Software.
- We will preserve attribution to "M5Stack Technology CO LTD" by reproducing the full MIT license text in `mrbgems/picoruby-ili9342/LICENSE` (the file created in Task 5 of the plan), and that file will include a `Copyright (c) 2026 M5Stack Technology CO LTD` line **alongside** the `Copyright (c) 2026 bash0C7` line, because portions of the mrbgem are derived from the upstream MIT-licensed source.
- Pin numbers and datasheet-derived init sequences are largely facts about the hardware (uncopyrightable in many jurisdictions), but treating them as MIT-licensed expression and complying with the notice clause is the safe, conservative path.

This file documents the legal basis for transcribing pin numbers and ILI9342
initialization byte sequences from the upstream C++ source into our Pure-Ruby
mrbgem `picoruby-ili9342`.

Verification gate: Task 5 of the plan must add M5Stack copyright to the mrbgem's LICENSE file. If skipped, this transcription becomes non-compliant.
