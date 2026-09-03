# picoruby-ble ESP32 NimBLE Port Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the BTstack-based `mrbgems/picoruby-ble/ports/esp32/` with a NimBLE-based implementation (per picoruby/picoruby#427 review), keeping the Ruby layer, common src layer, and rp2040 port untouched.

**Architecture:** The port synthesizes BTstack-wire-format event packets from NimBLE callbacks and pushes them through the existing `BLE_push_event` mailbox, translates the Ruby-built BTstack att_db blob into `ble_gatt_svc_def` tables at `BLE_init`, and maintains a bidirectional map between blob (Ruby) attribute handles and NimBLE-assigned handles. A bounded FIFO + 150 ms dispatch timer paces event delivery into the single-slot mailbox that Ruby polls every 100 ms.

**Tech Stack:** ESP-IDF v5.4.2 `bt` component (NimBLE host, `CONFIG_BT_NIMBLE_ENABLED`), FreeRTOS, esp_timer. Verified against local headers at `~/esp/esp-idf/components/bt/host/nimble/` (API stable across IDF 5.0–5.4).

---

## Locked design decisions

1. **BTstack-format synthesis at the port boundary.** `mrblib/ble_central.rb` etc. parse BTstack event bytes at fixed offsets; `GattDatabase` emits BTstack att_db blobs. The port fabricates compatible bytes; zero changes outside `ports/esp32/`.
2. **Event pacing.** `src/mruby/ble.c` `BLE_push_event` is a single-slot last-writer-wins mailbox; Ruby polls at 100 ms (`POLLING_UNIT_MS`). NimBLE discovery callbacks burst (all results + EDONE back-to-back), which would guarantee loss. The port queues synthesized packets (16 × 100-byte entries, FreeRTOS critical section) and a periodic esp_timer (150 ms > 100 ms poll) pushes one per tick. Overflow: drop oldest ADV-report entry first, else drop incoming and log.
3. **Handle mapping.** Ruby assigns blob handles sequentially (`GattDatabase#push_handle`) and keys `read_values`/`write_values`/`notify` on them; NimBLE assigns its own handles. Parser records blob handles; registration fills NimBLE handles (`val_handle` out-ptr for chr values; `gatts_register_cb` + `dsc_def.arg` trick for descriptors; chr decl = val−1; auto-CCCD = val+1 per `ble_gatt.h` docs). Linear-scan map both directions.
4. **Blob translation rules.** 0x2800/0x2801 entries open a service (register blob's GAP/GATT services as-is; do NOT call `ble_svc_gap_init`/`ble_svc_gatt_init` — avoids duplicate 0x1800/0x1801). 0x2803 = characteristic declaration (properties byte → `BLE_GATT_CHR_F_*`); the following entry is its value attribute (static bytes served from the port-owned blob copy; `DYNAMIC` flag 0x100 → serve via `BLE_read_data`/`BLE_write_data`). 0x2902 CCCD: record ruby handle for SUBSCRIBE synthesis, do NOT create a dsc_def (NimBLE auto-creates CCCD). Other descriptors (0x2901, 0x2900, …) become `ble_gatt_dsc_def` with READ/WRITE att_flags. Database-hash char (0x2b2a) passes through as a static char (hash value will not match NimBLE's handle layout — same class of quirk as BTstack port, cosmetic).
5. **Subscribe → CCCD write synthesis.** NimBLE never calls the access callback for CCCD writes; `BLE_GAP_EVENT_SUBSCRIBE` fires instead. Port maps `subscribe.attr_handle` (= chr val handle) → that chr's ruby CCCD handle → `BLE_write_data(ruby_cccd, cur_notify ? "\x01\x00" : cur_indicate ? "\x02\x00" : "\x00\x00", 2)`. This is what makes the peripheral example's `pop_write_value(@configuration_handle)` work.
6. **Power model is soft.** `BLE_hci_power_control(ON)`: start 1 s heartbeat timer + enqueue `BTSTACK_EVENT_STATE(working)` (re-enqueued on every ON — Ruby's `scan`→`start` cycle depends on it). OFF: stop heartbeat, stop advertising, cancel scan; host stays up, connections stay (BTstack ESP32 port effectively behaved this way — power was applied at init and later calls were internal no-ops).
7. **Re-init works.** Second `BLE.new` in the same boot (R2P2 shell reruns apps): full teardown — stop adv/scan, `nimble_port_stop()`, `nimble_port_deinit()`, free defs/map — then fresh init. MicroPython-proven sequence.
8. **Address = public, no RPA.** `ble_hs_util_ensure_addr(0)` + `ble_hs_id_infer_auto(0, &own_addr_type)` at sync. Preserves the BTstack "Phase 1 fix" (no random-address rotation, no duplicate scanner entries). `BLE_gap_local_bd_addr` returns printed order → reverse NimBLE's little-endian 6 bytes.
9. **Security posture parity.** `ble_hs_cfg.sm_io_cap = BLE_HS_IO_NO_INPUT_OUTPUT`, `sm_bonding = 0`, `sm_mitm = 0`, `sm_sc = 0`. Just Works is NimBLE's default path; nothing surfaces to Ruby.
10. **Advertising parity.** itvl min=max=800 (500 ms), `BLE_GAP_CONN_MODE_UND` when connectable else `NON`, disc mode GEN, all channels. Raw AD bytes via `ble_gap_adv_set_data`. NimBLE stops advertising on connect: port re-arms on DISCONNECT if advertising was wanted (matches BTstack's persistent `gap_advertisements_enable(1)`).
11. **Characteristic end_handle reconstruction** (NimBLE omits it): buffer one chr per discovery, emit previous with `end = current.def_handle − 1`, emit last with the request's `end_handle` at EDONE (MicroPython's exact trick), then QUERY_COMPLETE.
12. **Central connect success only.** `BLE_GAP_EVENT_CONNECT` with `status != 0` synthesizes nothing (Ruby would treat a garbage handle as connected); app-level timeout handles retry. Deviation from BTstack (which forwarded failures too), safer.
13. **con_handle set on CONNECT** (peripheral), not on first ATT write (BTstack port quirk); cleared on DISCONNECT. Strictly better notify targeting; also set on ATT write for parity.
14. **Files keep the same layout** so R2P2-ESP32's explicit SRCS list changes minimally: `ble.c`, `ble_peripheral.c`, `ble_central.c` stay; `btstack_owner.{c,h}` → `nimble_owner.{c,h}`; `ble_common.h` becomes the port-internal shared header.

## Event wire formats to synthesize (byte-exact)

| Event | Layout (offset: field) |
|---|---|
| BTSTACK_EVENT_STATE 0x60 | `[0x60, 1, state]` — state 2 = HCI_STATE_WORKING |
| HCI_EVENT_DISCONNECTION_COMPLETE 0x05 | `[0x05, 4, status=0, handle lo, hi, reason]` |
| ATT_EVENT_MTU_EXCHANGE_COMPLETE 0xB5 | `[0xB5, 4, conn lo, hi, mtu lo, hi]` |
| ATT_EVENT_CAN_SEND_NOW 0xB7 | `[0xB7, 2, conn lo, hi]` (Ruby reads type only) |
| HCI_EVENT_LE_META 0x3E / conn complete | `[0x3E, 19, 0x01, status, handle16, role, peer_addr_type, peer_addr(6 LE), itvl16, latency16, timeout16, mca]` — Ruby reads subevent@2, handle@4–5 |
| GAP_EVENT_ADVERTISING_REPORT 0xDA | `[0xDA, len, adv_type, addr_type, addr(6 LE), rssi(int8), data_len, data…]` — NimBLE `disc_desc` maps 1:1 (`event_type`, `addr.type`, `addr.val`, `rssi`, `data`) |
| GATT_EVENT_QUERY_COMPLETE 0xA0 | `[0xA0, 3, conn16, att_status]` |
| GATT_EVENT_SERVICE_QUERY_RESULT 0xA1 | `[0xA1, 22, conn16, start16, end16, uuid128(16, little-endian)]` |
| GATT_EVENT_CHARACTERISTIC_QUERY_RESULT 0xA2 | `[0xA2, 28, conn16, start16(def), value16, end16, properties16, uuid128(16 LE)]` |
| GATT_EVENT_ALL_CHARACTERISTIC_DESCRIPTORS_QUERY_RESULT 0xA4 | `[0xA4, 20, conn16, handle16, uuid128(16 LE)]` |
| GATT_EVENT_CHARACTERISTIC_VALUE_QUERY_RESULT 0xA5 | `[0xA5, 4+n, conn16, value_handle16, length16, data…]` |
| GATT_EVENT_NOTIFICATION 0xA7 | `[0xA7, 4+n, conn16, value_handle16, length16, data…]` |

UUID128 wire order = NimBLE `ble_uuid128_t.value` order (both little-endian; Ruby `reverse_128`s for display). 16-bit UUIDs expand to the LE base: `FB 34 9B 5F 80 00 00 80 00 10 00 00 [lo] [hi] 00 00`.

## File structure

- Rewrite: `mrbgems/picoruby-ble/ports/esp32/ble.c` — `BLE_init` (blob parse → svc defs → host start), power control, local addr, GATT-client `BLE_*` wrappers + discovery callbacks + central/peripheral GAP event callback + all packet synthesis.
- Rewrite: `mrbgems/picoruby-ble/ports/esp32/ble_peripheral.c` — advertise/stop/notify/can-send-now.
- Rewrite: `mrbgems/picoruby-ble/ports/esp32/ble_common.h` — port-internal shared decls (role, con_handle, synth+enqueue API, handle map API, adv re-arm state).
- Rewrite: `mrbgems/picoruby-ble/ports/esp32/ble_central.c` — scan params/start/stop, connect.
- Create: `mrbgems/picoruby-ble/ports/esp32/nimble_owner.{c,h}` — host lifecycle (init/sync-wait/deinit), event FIFO + 150 ms dispatch timer, 1 s heartbeat timer.
- Delete: `mrbgems/picoruby-ble/ports/esp32/btstack_owner.{c,h}`.
- R2P2-ESP32: modify `components/picoruby-esp32/CMakeLists.txt` (SRCS rename, `PRIV_REQUIRES btstack` → `bt`), add `sdkconfigs/bt_nimble`, delete `components/btstack/` and `sdkconfigs/bt_btstack`, bump picoruby submodule.

## Tasks

### Task 1: nimble_owner — lifecycle + queues
**Files:** `ports/esp32/nimble_owner.{c,h}`

- [ ] `nimble_owner.h`: `int picoruby_nimble_start(void)` (idempotent; nvs_flash_init tolerant re-init, `nimble_port_init`, ble_hs_cfg wiring, `nimble_port_freertos_init`, 2 s sync wait → 0/-1), `int picoruby_nimble_stop(void)`, `bool picoruby_nimble_synced(void)`, `uint8_t picoruby_nimble_own_addr_type(void)`, `void picoruby_nimble_enqueue_event(const uint8_t *pkt, uint16_t len, bool is_adv_report)`, `void picoruby_nimble_heartbeat_enable(bool)`, `void picoruby_nimble_set_gatts_register_cb(...)` or expose `ble_hs_cfg` wiring hooks from ble.c before start.
- [ ] FIFO: `#define EVQ_DEPTH 16`, `#define EVQ_PKT_MAX 100`; ring of `{uint16_t len; uint8_t is_adv; uint8_t data[EVQ_PKT_MAX]}` under `portMUX_TYPE` critical section; dispatch esp_timer @150 ms pops one entry → `BLE_push_event`.
- [ ] Heartbeat esp_timer @1000 ms → `BLE_heartbeat()`.
- [ ] Build checkpoint: compiles (full build in Task 6).

### Task 2: blob parser + handle map + GATT server (ble.c part 1)
- [ ] Parser walks `[version][2B size][2B flags][2B handle][uuid(2|16 by LONG_UUID)][value…]…[0x0000]`, producing malloc'd `ble_gatt_svc_def[]`/`chr_def[]`/`dsc_def[]` (+1 zero terminators), `ble_uuid_any_t` per attr, static values pointing into the port-owned blob copy; handle-map entries `{ruby, nimble, cccd_ruby}` per attribute.
- [ ] Property byte → `BLE_GATT_CHR_F_*`; blob CCCD presence or NOTIFY|INDICATE properties → F_NOTIFY/F_INDICATE.
- [ ] Shared access callback: map nimble→ruby; READ: DYNAMIC → `BLE_read_data`, else static bytes; `os_mbuf_append`; WRITE: flat-copy (≤256) → `BLE_write_data(ruby, …)`, update `con_handle`. ATT error codes on failure.
- [ ] `gatts_register_cb` fills nimble handles (chr via `val_handle` out-ptr also works; dsc via `ctxt->dsc.handle` matched by dsc_def pointer or arg).
- [ ] `BLE_init`: copy blob (`att_db_byte_length` walk, reused), parse, teardown-if-running, `ble_gatts_count_cfg`+`ble_gatts_add_svcs` before host start, start, return 0/−1.

### Task 3: peripheral (ble.c GAP cb + ble_peripheral.c)
- [ ] GAP event cb (peripheral): CONNECT (record con_handle; failed status → re-advertise), DISCONNECT (synth 0x05, clear handle, re-arm adv), MTU (synth 0xB5), SUBSCRIBE (synth CCCD write per decision 5).
- [ ] `BLE_peripheral_advertise`: `ble_gap_adv_set_data` + `ble_gap_adv_start(own, NULL, BLE_HS_FOREVER, &params, gap_cb, NULL)`; wanted-flag for re-arm. Stop clears flag + `ble_gap_adv_stop`.
- [ ] `BLE_peripheral_notify(ruby_handle)`: map → val_handle, `BLE_read_data`, `ble_hs_mbuf_from_flat` → `ble_gatts_notify_custom`.
- [ ] `BLE_peripheral_request_can_send_now_event`: enqueue synth 0xB7 immediately.
- [ ] `BLE_hci_power_control` + `BLE_gap_local_bd_addr` per decisions 6/8.

### Task 4: central + observer (ble_central.c + ble.c GATT client)
- [ ] Scan: stored params (0.625 ms units pass-through; passive = `!scan_type`), `ble_gap_disc(own, BLE_HS_FOREVER, &params, gap_cb, NULL)`; stop = `ble_gap_disc_cancel` (tolerate EALREADY).
- [ ] GAP cb (central/observer): DISC → synth 0xDA (adv-report coalescing flag); CONNECT status==0 → synth 0x3E; DISCONNECT → synth 0x05; NOTIFY_RX → synth 0xA7.
- [ ] `BLE_central_gap_connect`: cancel scan if active; reverse printed-order addr → `ble_addr_t`; conn params = rp2040 numbers (8/24/4/720/96/48/16/48); `ble_gap_connect(own, &peer, 30000, &params, gap_cb, NULL)`; map rc → uint8.
- [ ] Discovery wrappers + callbacks: `disc_all_svcs` → per-svc 0xA1, EDONE → 0xA0; `disc_all_chrs` → buffered end-handle trick → 0xA2s + 0xA0; `disc_all_dscs(value_handle, end)` → 0xA4s + 0xA0; `ble_gattc_read` → 0xA5 + 0xA0; `write_flat` (descriptor) → 0xA0 on cb; `write_no_rsp_flat` direct. One procedure at a time (guard flag), rc → uint8.

### Task 5: R2P2-ESP32 integration
- [ ] `components/picoruby-esp32/CMakeLists.txt`: `btstack_owner.c` → `nimble_owner.c`; `PRIV_REQUIRES` `btstack` → `bt`.
- [ ] Add `sdkconfigs/bt_nimble` (`CONFIG_BT_ENABLED=y`, `CONFIG_BT_NIMBLE_ENABLED=y`, `CONFIG_BT_BLUEDROID_ENABLED=n`, `CONFIG_SW_COEXIST_ENABLE=n`, NimBLE roles default-on, `CONFIG_BT_NIMBLE_MAX_CONNECTIONS=3`).
- [ ] Delete `components/btstack/`, `sdkconfigs/bt_btstack`.
- [ ] Point submodule at the new picoruby commit (local fetch).

### Task 6: build verification
- [ ] `source ~/esp/esp-idf/export.sh`; regenerate sdkconfig with `SDKCONFIG_DEFAULTS="sdkconfig.defaults;sdkconfigs/usb_console;sdkconfigs/bt_nimble"` (match previous build's fragment set, swapping bt fragment); `idf.py build` for esp32s3, `PICORB_VM=mruby`. Iterate to clean.

### Task 7: review + commit
- [ ] Adversarial review workflow over the full diff (correctness of synthesized formats vs mrblib parsing, handle-map edge cases, threading, mbuf ownership); fix confirmed findings.
- [ ] Local commits: picoruby (`ports/esp32` rewrite), R2P2-ESP32 (integration + submodule bump). No push.

## Known deviations from the BTstack port (to note in the PR)

- Central connect failures are not forwarded to Ruby (decision 12).
- POWER_OFF is soft (decision 6).
- Event delivery is paced at 150 ms via a FIFO instead of direct push — discovery is modestly slower but lossless where BTstack was probabilistically lossy.
- Database-hash characteristic value is served verbatim from the blob; it does not re-hash NimBLE's actual handle layout.
- Synthesized value events cap payloads at 92 bytes (EVQ_PKT_MAX − 8); long characteristic values truncate (BTstack capped at negotiated MTU instead).
- `SM_EVENT_JUST_WORKS_REQUEST` auto-confirm is unnecessary (NimBLE Just Works needs no app confirmation).

## Self-adversarial review brief (post-/compact continuation)

State: implemented, esp32s3+IDF v5.4.2 build green, committed — picoruby `5792bd79` (picoruby-ble-esp32-port), R2P2-ESP32 `17a3cef` (stackchan-integration). Self-adversarial review DONE (2026-07-03): all wire formats byte-checked against mrblib offsets, blob parser checked against every GattDatabase emission pattern, NimBLE sources confirmed notify_custom mbuf ownership / SUBSCRIBE attr_handle = chr value handle / ble_gatts_stop called from ble_hs_deinit. One confirmed finding fixed: EVQ_DEPTH 16→32 (a single ATT read-by-type response at MTU 256 can burst ~28 discovery callbacks; 16 silently dropped the overflow). Review fixes = NEW commits (amend/push need user approval).

**Ground truth to re-read (do not trust summaries):** the 6 port files under `mrbgems/picoruby-ble/ports/esp32/` in full; `mrblib/ble_central.rb` (event codes L3-19, offsets L84-301), `mrblib/ble_advertising_report.rb` (raises if packet < 14 bytes; offsets 2/3/4-9/10/11/12), `mrblib/ble_gatt_database.rb` (blob format), `src/mruby/ble.c` (single-slot mailbox `BLE_push_event`, write_values queue, read_values hash), `example/peripheral-central/peripheral/app.rb`; NimBLE actual sources at `~/esp/esp-idf/components/bt/host/nimble/`.

**Do NOT report (accepted deviations):** soft POWER_OFF; central connect failures unforwarded; 150 ms pacing; 92-byte value cap; broadcaster ADV_NONCONN_IND; stale database-hash char; Ruby central value-read state machine misattributing A0s (upstream design, lossy on BTstack too); mruby alloc from non-VM task in BLE_push_event/BLE_write_data (BTstack-port parity — only NEW races count).

**Attack here (self-identified weak points):**
- `parse_att_db` terminator-slot accounting on every close path vs MAX_CHR_SLOTS/MAX_DSC_SLOTS bounds; services w/o chars; value-less char + following descriptor (uuid-match guard added — verify); uuid32 (4-byte) service/char uuids.
- SUBSCRIBE path: `subscribe.attr_handle` is the chr VALUE handle; `find_map_by_nimble` must land on the value map entry carrying `cccd_ruby_handle`.
- Handle-map 0 ambiguity: `handle_r2n`/`n2r` return 0 for not-found, but nimble_handle is also 0 pre-registration; `BLE_peripheral_notify` guards 0 — check other callers.
- Re-init ordering: stop → free blob → parse → start; failure paths (sync timeout leaves started=false; parse fail leaves owned blob); stale attr_map during teardown window.
- Concurrency: evq `taskENTER_CRITICAL` from esp_timer task + host task; static 256-byte write buf (host-task-only claim).
- `chr_disc_prev` is one global (one GATT procedure at a time — Ruby drives serially; verify no overlap path).
- 0xDA synth is 12+dlen bytes; dlen<2 → Ruby AdvertisingReport raises (BTstack parity — but check my length byte math `p[1]=10+dlen`).
- LE_META synthesized only on connect success; `ble_svc_gap_init` deliberately NOT called (blob registers 0x1800; ESP-IDF does not auto-init it — verified by grep); `ble_gatts_stop()` zeroes registration counters in 5.4.2 (`ble_gatts.c:1620-1630`) so no MicroPython BSS-reset hack needed.
- Wire-format fidelity: check every synth against the table above byte-by-byte, esp. uuid128 LE expansion and A2 properties widening to 16-bit.

**Iteration loop:** edit in main repo → `cp` changed file(s) to `R2P2-ESP32/components/picoruby-esp32/picoruby/mrbgems/picoruby-ble/ports/esp32/` → `source ~/esp/esp-idf/export.sh && idf.py build` in R2P2-ESP32 (fragments already baked into existing sdkconfig; full recipe: `SDKCONFIG_DEFAULTS="sdkconfig.defaults;sdkconfigs/usb_console;sdkconfigs/cores3;sdkconfigs/bt_nimble" idf.py -DPICORB_VM=mruby build`). Finalize: commit in picoruby → in submodule `git fetch <main repo path> picoruby-ble-esp32-port && git checkout -f FETCH_HEAD` → commit R2P2. Unrelated-symbol link errors (I2S_*) → stale gem dir: `rm -rf components/picoruby-esp32/picoruby/build/esp32-picoruby`.

**Also pending:** hardware E2E (no device on USB; needs user to connect — then flash + stackchan-ble-control drive).

## E2E (hardware, after build)

Flash + monitor; run the stackchan peripheral driver from the PC client (`stackchan-ble-control`) against the device; verify: adv visible, connect, CCCD write reaches `pop_write_value`, notify received, writes land. Requires attached hardware — user assist if no device on USB.
