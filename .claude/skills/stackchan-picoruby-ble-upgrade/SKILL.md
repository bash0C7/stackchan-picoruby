---
name: stackchan-picoruby-ble-upgrade
description: Upgrade or switch the picoruby-ble lineage or rebase the firmware picoruby branch onto upstream master without reintroducing mrb_open stack overflow. Manual invocation only.
disable-model-invocation: true
effort: high
---

# `picoruby-ble` Lineage Switch & Firmware `picoruby` Rebase

Use this procedure whenever moving `picoruby-ble` to a new lineage or rebasing the firmware `picoruby` branch onto upstream `picoruby/picoruby` master. Known-good pins live in `acceptance/lock.yml`.

## 1. Whole-Gem Migration (No Cherry-Picks)

- Bring over the entire `picoruby-ble` gem (`mrblib/`, `src/`, `include/`, `sig/`, `mrbgem.rake`, plus `ports/esp32/{ble,ble_central,ble_peripheral,nimble_owner}.[ch]`) rather than cherry-picking individual fixes.
- Align the `mruby/mruby` submodule sha because `mruby-task`'s `mrb_task_queue_push` is required.
- Grep the migrated tree to verify names and visibility of `_event_popped`, `_event_queue_cleared`, `@event_queue`, and `hci_power_control`.

## 2. Preserve Zero-Raise `mrb_open` on Firmware Line

Upstream `picoruby-uart` (`require "irq"` / `include IRQ` inside `rescue`) and `picoruby-ble` (`require 'cyw43'` inside `rescue LoadError`) raise during `mrb_open` on ESP32 targets that lack those gems.
- Raising inside `mrb_open` nests an extra VM frame (~2,896 B), shrinking the 8 KB `picoruby_task` boot headroom from ~2,072 B to ~248 B and triggering `stack overflow in task picoruby_task` boot loops even with no app loaded.
- Keep the firmware `picoruby` line using `Kernel#extern` (returns `nil` for absent gems without raising).
- Run `bundle exec rake r2p2:qemu_check` immediately after rebasing — startup stack overflow reproduces reliably under QEMU.

## 3. `PICORB_TASK_STACK_SIZE` Boundary

- `PICORB_TASK_STACK_SIZE` (default 8 KB) is read from the environment by `vendor/R2P2-ESP32/components/picoruby-esp32/CMakeLists.txt`.
- `Rakefile`'s `r2p2_build_env` intentionally does not pass it, and it is not part of the acceptance firmware digest. Changing it invalidates the 8 KB drawing/BLE stack invariants and requires a full firmware reflash plus a fresh acceptance report. (Task stack lives in internal RAM; mruby heap lives in PSRAM.)

## 4. Verification Gate (Required Before Completion)

Compile success is not completion. Verify in order:
1. `bundle exec rake test` (host picotest + rigor)
2. `bundle exec rake r2p2:qemu_check` (boot + gem load + app eval without stack overflow)
3. Flash via `/stackchan-device-firmware` (`build-flash` or `full-rebuild`), then pass on physical hardware:
   - `r2p2:ble_control_smoke`
   - `r2p2:ble_servo_smoke`
   - `r2p2:ble_torque_smoke`
4. Complete `/stackchan-device-acceptance` with `verdict: pass` before merge.
