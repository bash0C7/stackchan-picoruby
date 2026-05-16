# BLE on CoreS3 (NUS + stackchan-protocol frame) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enable bidirectional BLE communication between CoreS3 StackChan running PicoRuby and Mac (CoreBluetooth / Chrome Web Bluetooth) using existing stackchan-protocol frames over Nordic UART Service.

**Architecture:** BTstack as host BLE stack on top of ESP-IDF v5.4 BT controller (VHCI transport, dedicated FreeRTOS task). The picoruby-ble gem is extended with a new `ports/esp32/` directory whose contents are 96% line-for-line copy of the existing `ports/rp2040/` port (only Pico SDK include lines and unused `blink_led` debug helper are removed). picoruby-ble-uart provides Nordic UART Service. Existing stackchan-protocol frame format (STX + Length(2B BE) + Cmd(1B) + Payload + CRC16(2B BE)) flows over NUS RX/TX characteristics, reusing the PC-side FrameWriter / FrameParser code unchanged.

**Tech Stack:** PicoRuby (R2P2-ESP32), BTstack (vendored at `picoruby/picoruby/mrbgems/picoruby-r2p2/lib/pico-sdk/lib/btstack/`), ESP-IDF v5.4, ESP32-S3 (M5Stack CoreS3), Ruby (Mac side: `core_bluetooth` gem), Chrome Web Bluetooth API. Reference doc: `docs/superpowers/specs/2026-05-15-ble-bringup-trace.md`.

**Repository touch points:**

- `bash0C7/stackchan-picoruby` (current repo) — new examples, PC client transport, web demo, plan/spec
- `bash0C7/R2P2-ESP32` — new sdkconfig fragment, new BTstack idf component, build_config gem additions, smoke hook in `main/main.c`
- `picoruby/picoruby` (local clone, branch `feature/ble-esp32-port`) — new `mrbgems/picoruby-ble/ports/esp32/`, mrbgem.rake platform branching. Push to bash0C7 fork only after Phase 1 stable.

**Phase boundaries (each phase produces working artifact and is committed independently):**

- **Phase 0**: BTstack on ESP-IDF v5.4 + ESP32-S3 advertise smoke. Zero PicoRuby involvement. Verifies BTstack itself works on this IDF version. Deliverable: device advertises name `StackChan-bts`, visible from Chrome `chrome://bluetooth-internals`.
- **Phase 1**: picoruby-ble/ports/esp32 implementation + R2P2-ESP32 integration. Deliverable: a PicoRuby script `BLE.new(:peripheral, ...)` advertises and `ble_irb` via Web Bluetooth gives a Ruby REPL over BLE.
- **Phase 2**: NUS + stackchan-protocol frame on top. Deliverable: Mac Ruby script and Chrome HTML page can both change StackChan face by sending an `F` frame over NUS.

**Test strategy honesty note:**

BLE / firmware / hardware integration cannot be TDD'd in the conventional red-green-refactor sense. For Phase 0 and Phase 1 tasks that touch firmware, the "test" is a clearly-defined smoke verification on real hardware with explicit pass criteria (e.g., "Chrome shows the device with name X within 30 seconds of reset"). For Phase 2, the PC-side code (transport abstraction, frame encode/decode) is conventional Ruby + test-unit and follows TDD.

**Operational notes (from project CLAUDE.md):**

- All `rake r2p2:*` tasks must run via subagent (general-purpose, model haiku) foreground. Never use screen `-dmS` longrun pattern.
- Physical board operations (reset button, USB unplug, monitor + `rm /home/app.rb`) are delegated to the human, not retried by claude.
- The PicoRuby `require` name strips the `picoruby-` prefix and keeps hyphens (e.g., `picoruby-ble` → `require 'ble'`).
- Adding a new gem to `xtensa-esp-picoruby.rb` requires `rake r2p2:setup` (10–20 minutes); modifying existing gem `mrblib/*.rb` only requires the lighter `picoruby` rake re-run + `rake r2p2:flash`.

---

## Phase 0: BTstack + ESP-IDF v5.4 advertise smoke

**Goal of Phase 0:** Prove BTstack vendored ESP32 port builds and advertises on ESP-IDF v5.4 + ESP32-S3, side-by-side with R2P2's existing main.

**Deliverable:** R2P2-ESP32 firmware that boots PicoRuby normally AND in parallel advertises a BLE peripheral named `StackChan-bts`. Visible from Chrome `chrome://bluetooth-internals` and Mac CoreBluetooth scan.

**Risk bucket:** This phase contains the largest unknown — whether BTstack's `port/esp32/` (tested with v4.4 / v5.0) works on v5.4 without source patches. If it fails, the most likely fix is adjusting `esp_bt_controller_*` calls to v5.4 signatures; worst case is patching `btstack_port_esp32.c` line-by-line.

### File Structure (Phase 0)

| File | Action | Responsibility |
|---|---|---|
| `bash0C7/R2P2-ESP32/sdkconfigs/bt_btstack` | **Create** | BLE+BTstack sdkconfig fragment |
| `bash0C7/R2P2-ESP32/components/btstack/CMakeLists.txt` | **Create** | idf_component_register for BTstack source files |
| `bash0C7/R2P2-ESP32/components/btstack/btstack_config.h` | **Create** | Minimal BTstack feature config (BLE only, FreeRTOS run loop) |
| `bash0C7/R2P2-ESP32/components/btstack/btstack_port_esp32.c` | **Create** | Symlink or copy from picoruby tree's vendored BTstack port/esp32 |
| `bash0C7/R2P2-ESP32/main/btstack_smoke.c` | **Create** | Minimal `btstack_main()` + FreeRTOS task wrapper |
| `bash0C7/R2P2-ESP32/main/btstack_smoke.h` | **Create** | Public `void btstack_smoke_start(void);` |
| `bash0C7/R2P2-ESP32/main/btstack_smoke.gatt` | **Create** | GATT database source for smoke (GAP service + counter char) |
| `bash0C7/R2P2-ESP32/main/btstack_smoke_gatt.h` | **Generate** | Output of `compile_gatt.py btstack_smoke.gatt`. Committed (so build does not require Python at every build) |
| `bash0C7/R2P2-ESP32/main/main.c` | **Modify** | Call `btstack_smoke_start()` before `picoruby_esp32()` when `CONFIG_BTSTACK_SMOKE=y` |
| `bash0C7/R2P2-ESP32/main/CMakeLists.txt` | **Modify** | Add btstack_smoke.c, REQUIRES btstack |
| `bash0C7/stackchan-picoruby/Rakefile` | **Modify** | Append `;sdkconfigs/bt_btstack` to `SDKCONFIG_DEFAULTS` env |

### Task 0.1: Branch and verify clean state

**Files:** none (git operations only)

- [ ] **Step 1: Verify current state**

Delegate to subagent (general-purpose):
```
Run these git commands in /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby and report a 5-line summary (current branch / dirty? / latest commit / latest commit subject):
  git branch --show-current
  git status --porcelain | head
  git log --oneline -1
```

Expected: branch `feature/stackchan-display-bringup`, clean tree, tip `f50780e` or descendant.

- [ ] **Step 2: Create new feature branch in stackchan-picoruby**

Delegate to subagent (general-purpose):
```
In /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby:
  git checkout -b feature/ble-bringup
Report new branch name.
```

Expected: now on `feature/ble-bringup`.

- [ ] **Step 3: Verify R2P2-ESP32 state**

Delegate to subagent (general-purpose):
```
In /Users/bash/dev/src/github.com/bash0C7/R2P2-ESP32 report:
  git branch --show-current
  git status --porcelain | head
  git log --oneline -1
```

Expected: branch `feature/cores3-stackchan` (or similar), clean tree.

- [ ] **Step 4: Create new feature branch in R2P2-ESP32**

Delegate to subagent (general-purpose):
```
In /Users/bash/dev/src/github.com/bash0C7/R2P2-ESP32:
  git checkout -b feature/ble-bringup
```

- [ ] **Step 5: Verify picoruby clone state and create branch**

Delegate to subagent (general-purpose):
```
In /Users/bash/dev/src/github.com/picoruby/picoruby:
  git branch --show-current
  git status --porcelain | head
  git log --oneline -1
Then: git checkout -b feature/ble-esp32-port
Report results.
```

Expected: was on `master` (or main) clean, now on `feature/ble-esp32-port`.

### Task 0.2: Create BLE+BTstack sdkconfig fragment

**Files:**
- Create: `/Users/bash/dev/src/github.com/bash0C7/R2P2-ESP32/sdkconfigs/bt_btstack`

- [ ] **Step 1: Write the fragment**

```
# BLE + BTstack host stack sdkconfig fragment (ESP-IDF v5.4 / ESP32-S3 / BLE only)

CONFIG_BT_ENABLED=y
CONFIG_BT_CONTROLLER_ENABLED=y
CONFIG_BT_CONTROLLER_ONLY=y
CONFIG_BT_BLUEDROID_ENABLED=n
CONFIG_BT_NIMBLE_ENABLED=n

# Controller
CONFIG_BTDM_CTRL_MODE_BLE_ONLY=y
CONFIG_BTDM_CTRL_HCI_MODE_VHCI=y
CONFIG_BT_CTRL_HCI_TL_EFF=1
CONFIG_BTDM_CTRL_BLE_MAX_CONN=4
CONFIG_BTDM_BLE_SCAN_DUPL=y
CONFIG_BT_RESERVE_DRAM=0xdb5c

# Smoke gate (Phase 0 only; remove or set to n for Phase 1+)
CONFIG_BTSTACK_SMOKE=y
```

- [ ] **Step 2: Verify file exists and is well-formed**

Delegate to subagent (general-purpose):
```
Run: cat /Users/bash/dev/src/github.com/bash0C7/R2P2-ESP32/sdkconfigs/bt_btstack
Report line count and last 5 lines.
```

Expected: ~15 lines, ending with `CONFIG_BTSTACK_SMOKE=y`.

- [ ] **Step 3: No commit yet** (we commit at end of Phase 0 task group, see Task 0.11)

### Task 0.3: Wire fragment into Rakefile SDKCONFIG_DEFAULTS

**Files:**
- Modify: `/Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/Rakefile`

- [ ] **Step 1: Read current SDKCONFIG_DEFAULTS line**

```
Run: grep -n SDKCONFIG_DEFAULTS /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/Rakefile
Report all matching lines.
```

Expected: one line setting env var with `sdkconfig.defaults;sdkconfigs/usb_console;sdkconfigs/cores3`.

- [ ] **Step 2: Edit Rakefile to append `;sdkconfigs/bt_btstack`**

Use Edit tool with exact match. Replace
```
sdkconfig.defaults;sdkconfigs/usb_console;sdkconfigs/cores3
```
with
```
sdkconfig.defaults;sdkconfigs/usb_console;sdkconfigs/cores3;sdkconfigs/bt_btstack
```

- [ ] **Step 3: Verify edit**

```
Run: grep -n SDKCONFIG_DEFAULTS /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/Rakefile
Report matching lines.
```

Expected: one line ending `sdkconfigs/bt_btstack`.

### Task 0.4: Vendor BTstack source into R2P2-ESP32 idf component

**Background:** The BTstack sources are already vendored at `/Users/bash/dev/src/github.com/picoruby/picoruby/mrbgems/picoruby-r2p2/lib/pico-sdk/lib/btstack/`. We need to make ESP-IDF treat them as a component. The official `integrate_btstack.py` copies them into `$IDF_PATH/components/btstack/` — we will replicate that effect by creating a thin idf component in `R2P2-ESP32/components/btstack/` that includes the picoruby-tree paths.

We choose **option B: thin component with INCLUDE_DIRS pointing into picoruby tree** (no file copy) so the BTstack source stays single-sourced. Tradeoff: tight coupling to picoruby clone path, but acceptable because R2P2-ESP32 already references it via the picoruby-esp32 component.

**Files:**
- Create: `/Users/bash/dev/src/github.com/bash0C7/R2P2-ESP32/components/btstack/CMakeLists.txt`
- Create: `/Users/bash/dev/src/github.com/bash0C7/R2P2-ESP32/components/btstack/btstack_config.h`

- [ ] **Step 1: Create CMakeLists.txt for the BTstack component**

```cmake
# components/btstack/CMakeLists.txt
# Wraps the BTstack source vendored at picoruby/picoruby/mrbgems/picoruby-r2p2/lib/pico-sdk/lib/btstack/

set(BTSTACK_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../picoruby-esp32/picoruby/mrbgems/picoruby-r2p2/lib/pico-sdk/lib/btstack")

# Core BTstack sources required for BLE peripheral
file(GLOB BTSTACK_SRC_CORE
    "${BTSTACK_ROOT}/src/*.c"
    "${BTSTACK_ROOT}/src/ble/*.c"
    "${BTSTACK_ROOT}/src/ble/gatt-service/*.c"
)

# Exclude classic-only sources (we have BLE only target)
set(EXCLUDE_PATTERNS
    "btstack_audio_embedded"
    "btstack_chipset_"
    "btstack_signal"
    "hci_dump_posix_fs"
    "hci_dump_segger_rtt_stdout"
    "hci_dump_posix_stdout"
    "hci_transport_h2_libusb"
    "hci_transport_h4"
    "hci_transport_h5"
    "hci_transport_em9304_spi"
    "btstack_chipset_em9301"
    "wav_util"
)

foreach(pattern ${EXCLUDE_PATTERNS})
    list(FILTER BTSTACK_SRC_CORE EXCLUDE REGEX ".*${pattern}.*")
endforeach()

# ESP32-specific port
set(BTSTACK_SRC_ESP32
    "${BTSTACK_ROOT}/port/esp32/components/btstack/btstack_port_esp32.c"
    "${BTSTACK_ROOT}/port/esp32/components/btstack/btstack_tlv_esp32.c"
    "${BTSTACK_ROOT}/platform/freertos/btstack_run_loop_freertos.c"
    "${BTSTACK_ROOT}/platform/embedded/hci_dump_embedded_stdout.c"
)

idf_component_register(
    SRCS ${BTSTACK_SRC_CORE} ${BTSTACK_SRC_ESP32}
    INCLUDE_DIRS
        "."
        "${BTSTACK_ROOT}/src"
        "${BTSTACK_ROOT}/src/ble"
        "${BTSTACK_ROOT}/src/ble/gatt-service"
        "${BTSTACK_ROOT}/3rd-party/micro-ecc"
        "${BTSTACK_ROOT}/3rd-party/bluedroid/decoder/include"
        "${BTSTACK_ROOT}/3rd-party/bluedroid/encoder/include"
        "${BTSTACK_ROOT}/platform/freertos"
        "${BTSTACK_ROOT}/platform/embedded"
        "${BTSTACK_ROOT}/port/esp32/components/btstack"
    REQUIRES bt nvs_flash
)

target_compile_options(${COMPONENT_LIB} PRIVATE -Wno-unused-variable -Wno-unused-function -Wno-format)
target_compile_definitions(${COMPONENT_LIB} PRIVATE HAVE_FREERTOS_TASK_NOTIFICATIONS=1)
```

- [ ] **Step 2: Create btstack_config.h**

```c
// components/btstack/btstack_config.h
// Minimal BTstack feature configuration: BLE peripheral + central, FreeRTOS run loop.

#ifndef BTSTACK_CONFIG_H
#define BTSTACK_CONFIG_H

// Port-specific
#define HAVE_FREERTOS_TASK_NOTIFICATIONS
#define HAVE_MALLOC
#define HAVE_ASSERT

// BLE features
#define ENABLE_BLE
#define ENABLE_LE_PERIPHERAL
#define ENABLE_LE_CENTRAL
#define ENABLE_LE_SECURE_CONNECTIONS
#define ENABLE_LE_DATA_LENGTH_EXTENSION
#define ENABLE_L2CAP_LE_CREDIT_BASED_FLOW_CONTROL_MODE
#define ENABLE_GATT_CLIENT_PAIRING
#define ENABLE_PRINTF_HEXDUMP
#define ENABLE_LOG_INFO
#define ENABLE_LOG_ERROR

// Sizes
#define HCI_HOST_ACL_PACKET_NUM     20
#define HCI_HOST_ACL_PACKET_LEN     1024
#define HCI_HOST_SCO_PACKET_NUM     0
#define HCI_HOST_SCO_PACKET_LEN     0
#define HCI_ACL_PAYLOAD_SIZE        (1024+4)
#define HCI_INCOMING_PRE_BUFFER_SIZE 14
#define MAX_NR_HCI_CONNECTIONS      4
#define MAX_NR_GATT_CLIENTS         1
#define MAX_NR_SM_LOOKUP_ENTRIES    3
#define MAX_NR_LE_DEVICE_DB_ENTRIES 4
#define MAX_NR_WHITELIST_ENTRIES    4
#define MAX_ATT_DB_SIZE             512

// VHCI asynchronous mode (ESP32 port requires this)
#define ENABLE_ESP32_VHCI_ASYNCHRONOUS

// NVS namespace (BTstack uses "BTstack" — no conflict with R2P2 LittleFS)
#define NVS_PARTITION  "nvs"

#endif // BTSTACK_CONFIG_H
```

- [ ] **Step 3: Verify both files exist**

```
Run: ls -la /Users/bash/dev/src/github.com/bash0C7/R2P2-ESP32/components/btstack/
Report file list.
```

Expected: `CMakeLists.txt`, `btstack_config.h`.

### Task 0.5: Create the smoke GATT database

**Files:**
- Create: `/Users/bash/dev/src/github.com/bash0C7/R2P2-ESP32/main/btstack_smoke.gatt`
- Generate: `/Users/bash/dev/src/github.com/bash0C7/R2P2-ESP32/main/btstack_smoke_gatt.h`

- [ ] **Step 1: Write the .gatt source**

```
// btstack_smoke.gatt — Minimal GATT for Phase 0 smoke
// One GAP service with device name + one custom service with a counter characteristic.

PRIMARY_SERVICE, GAP_SERVICE
CHARACTERISTIC, GAP_DEVICE_NAME, READ, "StackChan-bts"
CHARACTERISTIC, GAP_APPEARANCE, READ, 0x0000

PRIMARY_SERVICE, GATT_SERVICE
CHARACTERISTIC, GATT_DATABASE_HASH, READ,

// Custom counter service (UUID is arbitrary 128-bit, vendor-specific)
PRIMARY_SERVICE, F00DBABE-1234-5678-1234-56789ABCDEF0
CHARACTERISTIC, F00DBABE-1234-5678-1234-56789ABCDEF1, READ | NOTIFY | DYNAMIC,
```

- [ ] **Step 2: Compile .gatt to .h**

Delegate to subagent (general-purpose, model haiku):
```
Run:
  cd /Users/bash/dev/src/github.com/bash0C7/R2P2-ESP32/main && \
    python3 /Users/bash/dev/src/github.com/picoruby/picoruby/mrbgems/picoruby-r2p2/lib/pico-sdk/lib/btstack/tool/compile_gatt.py \
      btstack_smoke.gatt btstack_smoke_gatt.h

Then run: ls -la btstack_smoke_gatt.h && head -30 btstack_smoke_gatt.h

Report exit code, file size, and first 30 lines.
```

Expected: file created (~few hundred bytes), header begins with `// HANDLE_F00DBABE...` or similar generated comments.

**Note (Python carve-out):** The project's "no Python" rule is for *runtime tooling* (e.g., uploader). BTstack's `compile_gatt.py` is a build-time generator vendored from upstream BTstack, run once per `.gatt` change, and its output (`*.h`) is the file we commit. Treat it like running `bison` or `yacc` — a build artifact generator. We commit the generated `.h` so the build pipeline itself never invokes Python.

- [ ] **Step 3: Verify generated header**

```
Run: wc -l /Users/bash/dev/src/github.com/bash0C7/R2P2-ESP32/main/btstack_smoke_gatt.h
Report line count.
```

Expected: 30–80 lines.

### Task 0.6: Write the smoke C app

**Files:**
- Create: `/Users/bash/dev/src/github.com/bash0C7/R2P2-ESP32/main/btstack_smoke.h`
- Create: `/Users/bash/dev/src/github.com/bash0C7/R2P2-ESP32/main/btstack_smoke.c`

- [ ] **Step 1: Write the header**

```c
// main/btstack_smoke.h
#ifndef BTSTACK_SMOKE_H
#define BTSTACK_SMOKE_H

#ifdef __cplusplus
extern "C" {
#endif

// Spawns a FreeRTOS task that runs btstack_init, configures a minimal GATT,
// and starts advertising as "StackChan-bts". Idempotent at the task-creation
// level (creates only on first call). Phase 0 smoke only.
void btstack_smoke_start(void);

#ifdef __cplusplus
}
#endif

#endif // BTSTACK_SMOKE_H
```

- [ ] **Step 2: Write the implementation**

```c
// main/btstack_smoke.c — Phase 0 BLE peripheral smoke
//
// Verifies BTstack vendored ESP32 port runs on ESP-IDF v5.4 + ESP32-S3.
// Spawns a dedicated FreeRTOS task that initializes BTstack and advertises
// a minimal GATT counter service named "StackChan-bts".
//
// On success, the device is visible from Chrome chrome://bluetooth-internals
// and from Mac CoreBluetooth scan.
//
// Remove or gate this file once Phase 1 ships picoruby-ble support.

#include "btstack_smoke.h"
#include "btstack.h"
#include "btstack_run_loop_freertos.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_log.h"

#include "btstack_smoke_gatt.h"

static const char *TAG = "btstack-smoke";

static btstack_packet_callback_registration_t hci_event_callback_registration;
static uint8_t counter_value = 0;
static btstack_timer_source_t counter_timer;

static const uint8_t adv_data[] = {
    // Length, Type, Value
    0x02, BLUETOOTH_DATA_TYPE_FLAGS, 0x06,                              // LE General Discoverable, BR/EDR not supported
    0x0E, BLUETOOTH_DATA_TYPE_COMPLETE_LOCAL_NAME,
    'S','t','a','c','k','C','h','a','n','-','b','t','s'
};

static uint16_t att_read_callback(hci_con_handle_t connection_handle,
                                  uint16_t att_handle,
                                  uint16_t offset,
                                  uint8_t *buffer,
                                  uint16_t buffer_size) {
    (void)connection_handle;
    if (att_handle == ATT_CHARACTERISTIC_F00DBABE_1234_5678_1234_56789ABCDEF1_01_VALUE_HANDLE) {
        return att_read_callback_handle_byte(counter_value, offset, buffer, buffer_size);
    }
    return 0;
}

static void packet_handler(uint8_t packet_type,
                           uint16_t channel,
                           uint8_t *packet,
                           uint16_t size) {
    (void)channel; (void)size;
    if (packet_type != HCI_EVENT_PACKET) return;
    switch (hci_event_packet_get_type(packet)) {
        case BTSTACK_EVENT_STATE: {
            if (btstack_event_state_get_state(packet) == HCI_STATE_WORKING) {
                bd_addr_t addr;
                gap_local_bd_addr(addr);
                ESP_LOGI(TAG, "BTstack up. BD_ADDR=%02x:%02x:%02x:%02x:%02x:%02x",
                         addr[0], addr[1], addr[2], addr[3], addr[4], addr[5]);
            }
            break;
        }
        case HCI_EVENT_LE_META: {
            if (hci_event_le_meta_get_subevent_code(packet) == HCI_SUBEVENT_LE_CONNECTION_COMPLETE) {
                ESP_LOGI(TAG, "BLE connected");
            }
            break;
        }
        case HCI_EVENT_DISCONNECTION_COMPLETE: {
            ESP_LOGI(TAG, "BLE disconnected, advertising again");
            break;
        }
        default:
            break;
    }
}

static void counter_handler(struct btstack_timer_source *ts) {
    counter_value++;
    btstack_run_loop_set_timer(ts, 1000);
    btstack_run_loop_add_timer(ts);
}

static void btstack_main(void) {
    hci_event_callback_registration.callback = &packet_handler;
    hci_add_event_handler(&hci_event_callback_registration);

    l2cap_init();
    sm_init();
    att_server_init(profile_data, &att_read_callback, NULL);
    att_server_register_packet_handler(&packet_handler);

    bd_addr_t null_addr = {0};
    gap_advertisements_set_params(0x0030, 0x0030, 0, 0, null_addr, 0x07, 0x00);
    gap_advertisements_set_data(sizeof(adv_data), (uint8_t *)adv_data);
    gap_advertisements_enable(1);

    counter_timer.process = &counter_handler;
    btstack_run_loop_set_timer(&counter_timer, 1000);
    btstack_run_loop_add_timer(&counter_timer);

    hci_power_control(HCI_POWER_ON);
}

static void btstack_task(void *param) {
    (void)param;
    ESP_LOGI(TAG, "btstack_task starting");
    btstack_init();      // includes esp_bt_controller_init/enable + VHCI bridge
    btstack_main();
    btstack_run_loop_execute();   // blocks forever
    vTaskDelete(NULL);   // unreachable
}

void btstack_smoke_start(void) {
    static bool started = false;
    if (started) return;
    started = true;
    xTaskCreate(btstack_task, "btstack", 8192, NULL, 5, NULL);
}
```

- [ ] **Step 3: Verify both files**

```
Run: ls -la /Users/bash/dev/src/github.com/bash0C7/R2P2-ESP32/main/btstack_smoke* && wc -l /Users/bash/dev/src/github.com/bash0C7/R2P2-ESP32/main/btstack_smoke.c
Report.
```

Expected: 4 files (`.h`, `.c`, `.gatt`, `_gatt.h`); btstack_smoke.c around 90–110 lines.

### Task 0.7: Modify R2P2-ESP32 main to invoke smoke

**Files:**
- Modify: `/Users/bash/dev/src/github.com/bash0C7/R2P2-ESP32/main/main.c`
- Modify: `/Users/bash/dev/src/github.com/bash0C7/R2P2-ESP32/main/CMakeLists.txt`

- [ ] **Step 1: Edit main.c — add btstack_smoke_start() call**

Read current main.c:
```
Run: cat /Users/bash/dev/src/github.com/bash0C7/R2P2-ESP32/main/main.c
```
Expected current content (3 lines + blank):
```
#include "picoruby-esp32.h"

void app_main(void)
{
  picoruby_esp32();
}
```

Replace whole file with:
```c
#include "picoruby-esp32.h"
#include "sdkconfig.h"

#ifdef CONFIG_BTSTACK_SMOKE
#include "btstack_smoke.h"
#endif

void app_main(void)
{
#ifdef CONFIG_BTSTACK_SMOKE
  btstack_smoke_start();
#endif
  picoruby_esp32();
}
```

- [ ] **Step 2: Edit main/CMakeLists.txt — add btstack_smoke.c**

Replace current `idf_component_register(...)` block with:

```cmake
idf_component_register(
  SRCS "main.c" "btstack_smoke.c"
  REQUIRES picoruby-esp32 btstack
  PRIV_REQUIRES spi_flash
  INCLUDE_DIRS ""
)

set(image ../storage)
littlefs_create_partition_image(storage ${image} FLASH_IN_PROJECT)
```

- [ ] **Step 3: Add Kconfig entry for `CONFIG_BTSTACK_SMOKE`**

Read or create: `/Users/bash/dev/src/github.com/bash0C7/R2P2-ESP32/main/Kconfig.projbuild`

If it doesn't exist, create with:
```
menu "StackChan BLE smoke (Phase 0 only)"
    config BTSTACK_SMOKE
        bool "Enable BTstack BLE peripheral smoke task"
        default n
        help
            When enabled, app_main spawns a FreeRTOS task that brings up BTstack
            and advertises 'StackChan-bts'. Used to verify ESP-IDF + BTstack
            integration before PicoRuby BLE port is wired up. Remove for production.
endmenu
```

If it already has content, **append** the menu block.

- [ ] **Step 4: Verify all edits**

```
Run:
  cat /Users/bash/dev/src/github.com/bash0C7/R2P2-ESP32/main/main.c
  cat /Users/bash/dev/src/github.com/bash0C7/R2P2-ESP32/main/CMakeLists.txt
  cat /Users/bash/dev/src/github.com/bash0C7/R2P2-ESP32/main/Kconfig.projbuild
Report each file's contents.
```

Expected: main.c contains the conditional include + call, CMakeLists.txt SRCS includes both sources and REQUIRES includes btstack, Kconfig has the menu.

### Task 0.8: Setup R2P2 (gem rebuild needed only if first BT build)

**Files:** none (build system invocation)

- [ ] **Step 1: Run r2p2:setup foreground via subagent**

Delegate to subagent (general-purpose, model haiku, **timeout 1200000ms** — this is a 10–20 minute job):
```
Run from /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby:
  rake r2p2:setup

Report only:
  - exit code
  - last 30 lines of output
  - any line containing "error" or "ERROR" (case insensitive)

Do not return the full build log.
```

Pass criteria: exit code 0. Failures most commonly mean missing `idf.py` toolchain — investigate before continuing.

### Task 0.9: First build (smoke build)

**Files:** none (build system invocation)

- [ ] **Step 1: Build via subagent**

Delegate to subagent (general-purpose, model haiku, **timeout 600000ms**):
```
Run from /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby:
  rake r2p2:build

Report:
  - exit code
  - last 30 lines of output
  - any line containing "error" / "warning: implicit declaration" / "undefined reference"

Do not return the full build log.
```

Pass criteria: exit code 0. Common failures and fixes:

| Symptom | Fix |
|---|---|
| `undefined reference to esp_bt_controller_init` | `CONFIG_BT_ENABLED` not picked up — verify Rakefile SDKCONFIG_DEFAULTS edit (Task 0.3) |
| `fatal error: btstack.h: No such file or directory` | btstack component not registered — re-check CMakeLists.txt INCLUDE_DIRS (Task 0.4) |
| `error: 'BLUETOOTH_DATA_TYPE_FLAGS' undeclared` | btstack source list incomplete — check Task 0.4 src globbing |
| Hundreds of warnings about unused functions | Expected from BTstack source. Already suppressed via `-Wno-unused-function` in CMakeLists.txt |

If build fails with v5.4-specific errors (e.g., changed `esp_bt_controller_config_t` field), record the specific compile error in `docs/superpowers/specs/2026-05-15-ble-bringup-trace.md` Risk section and pause for spec amendment before continuing.

### Task 0.10: Flash + smoke verification

**Files:** none

- [ ] **Step 1: Flash via subagent**

Delegate to subagent (general-purpose, model haiku, timeout 600000ms):
```
Run from /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby:
  rake r2p2:flash

Report:
  - exit code
  - last 20 lines of output
  - whether "Hash of data verified" or similar success line appears
```

Pass criteria: exit code 0, esptool reports successful write.

- [ ] **Step 2: Human reset**

**Hand off to human:** "Please press the reset button on the CoreS3, then wait ~5 seconds for boot."

Do not retry automatically.

- [ ] **Step 3: Verify advertisement from Chrome**

**Hand off to human:** "Open Chrome and navigate to chrome://bluetooth-internals/#devices. Click 'Start Scan'. Within 30 seconds you should see a device named 'StackChan-bts'. Report whether it appears."

Pass criteria: device visible. If not visible after 60 seconds:
- Confirm physical reset happened (LED state, LCD output)
- Have human run `cd ../../bash0C7/R2P2-ESP32 && rake monitor` in another terminal
- Look for `[btstack-smoke] BTstack up. BD_ADDR=...` log line. If missing, BTstack didn't initialize — check sdkconfig fragments or build log
- If log present but device invisible, RF / advertise data issue — verify `gap_advertisements_enable(1)` succeeded (BTSTACK_EVENT_STATE log)

- [ ] **Step 4: Verify advertisement from Mac CoreBluetooth (optional secondary check)**

**Hand off to human:** "Open the Mac terminal and run `system_profiler SPBluetoothDataType | grep -A 2 StackChan-bts` after enabling Bluetooth scanning in System Settings. Report whether StackChan-bts appears."

This is a secondary check. Chrome alone is sufficient for Phase 0 acceptance.

### Task 0.11: Commit Phase 0

**Files:** all of Phase 0

- [ ] **Step 1: Commit R2P2-ESP32 changes**

Delegate to subagent (general-purpose):
```
In /Users/bash/dev/src/github.com/bash0C7/R2P2-ESP32:
  git add sdkconfigs/bt_btstack components/btstack/ main/btstack_smoke.* main/btstack_smoke_gatt.h main/main.c main/CMakeLists.txt main/Kconfig.projbuild
  git status --short
  git diff --cached --stat
Report status and stat.
```

Then create the commit:
```
git commit -m "$(cat <<'EOF'
feat(ble): Phase 0 — BTstack on ESP-IDF v5.4 advertise smoke

Adds BLE+BTstack sdkconfig fragment, idf component wrapping BTstack
sources vendored in picoruby tree, and a smoke task in main that brings
up BTstack and advertises as 'StackChan-bts'. Gated by CONFIG_BTSTACK_SMOKE
so the smoke can be disabled without code edits once Phase 1 ships
picoruby-ble support.

Verified:
- builds on ESP-IDF v5.4 with ESP32-S3 target
- advertises visible from Chrome chrome://bluetooth-internals

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 2: Commit stackchan-picoruby changes (Rakefile + this plan)**

Delegate to subagent (general-purpose):
```
In /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby:
  git add Rakefile docs/superpowers/specs/2026-05-15-ble-bringup-trace.md docs/superpowers/plans/2026-05-15-ble-on-cores3.md
  git status --short
Report status.
```

Then commit:
```
git commit -m "$(cat <<'EOF'
docs(ble): add Phase 0 spec and plan, wire bt_btstack sdkconfig

Append sdkconfigs/bt_btstack to SDKCONFIG_DEFAULTS chain. Spec/plan
documents the 3-phase BLE bring-up (Phase 0 smoke / Phase 1 picoruby-ble
ports/esp32 / Phase 2 NUS+frame).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 1: picoruby-ble/ports/esp32 + R2P2-ESP32 integration

**Goal of Phase 1:** A PicoRuby script can call `BLE.new(:peripheral, profile)` and the device advertises. Follow-up: `ble_irb` works (Web Bluetooth gives a Ruby REPL over BLE).

**Deliverable:** `/home/app.rb` containing a 5-line BLE advertise script causes the device to advertise visible from Chrome. Phase 0 smoke is disabled (`CONFIG_BTSTACK_SMOKE=n`) so PicoRuby is the sole BLE driver.

**Risk bucket:** Lower than Phase 0 (BTstack already proven). Main risks:
- mrbgem.rake platform branching syntax / build_config naming
- BTstack already running in Phase 0 task → must not double-initialize when picoruby-ble starts. Solution: Phase 0 smoke is gated off; picoruby-ble owns the FreeRTOS task lifecycle.
- `picoruby-mbedtls` dependency: confirm it builds on ESP32 (it should — mbedtls is ESP-IDF standard)

### File Structure (Phase 1)

| File | Action | Responsibility |
|---|---|---|
| `picoruby/picoruby/mrbgems/picoruby-ble/ports/esp32/ble_common.h` | **Create** | extern declarations shared between port .c files |
| `picoruby/picoruby/mrbgems/picoruby-ble/ports/esp32/ble.c` | **Create** | Main port: BLE_init, packet_handler, heartbeat, GATT client forward (copy from rp2040 with Pico SDK includes removed) |
| `picoruby/picoruby/mrbgems/picoruby-ble/ports/esp32/ble_peripheral.c` | **Create** | advertise / notify / can_send_now (copy from rp2040) |
| `picoruby/picoruby/mrbgems/picoruby-ble/ports/esp32/ble_central.c` | **Create** | scan / connect (copy from rp2040) |
| `picoruby/picoruby/mrbgems/picoruby-ble/ports/esp32/btstack_owner.c` | **Create** | New: owns the BTstack FreeRTOS task lifecycle (init + run_loop_execute on first BLE_init) |
| `picoruby/picoruby/mrbgems/picoruby-ble/ports/esp32/btstack_owner.h` | **Create** | New: `void picoruby_btstack_ensure_started(void);` |
| `picoruby/picoruby/mrbgems/picoruby-ble/mrbgem.rake` | **Modify** | Platform branching for esp32 vs rp2040 |
| `bash0C7/R2P2-ESP32/components/picoruby-esp32/build_config/xtensa-esp-picoruby.rb` | **Modify** | Enable picoruby-ble + picoruby-ble-uart |
| `bash0C7/R2P2-ESP32/sdkconfigs/bt_btstack` | **Modify** | `CONFIG_BTSTACK_SMOKE=n` |
| `stackchan-picoruby/mrbgems/picoruby-stackchan-protocol/examples/ble_smoke.rb` | **Create** | Minimal `BLE.new(:peripheral)` advertise script |

### Task 1.1: Create ports/esp32 directory and ble_common.h

**Files:**
- Create: `/Users/bash/dev/src/github.com/picoruby/picoruby/mrbgems/picoruby-ble/ports/esp32/ble_common.h`

- [ ] **Step 1: Read RP2040 ble_common.h as reference**

```
Run: cat /Users/bash/dev/src/github.com/picoruby/picoruby/mrbgems/picoruby-ble/ports/rp2040/ble_common.h
Report contents.
```

- [ ] **Step 2: Create esp32 ble_common.h (copy with port-specific note)**

```c
// ports/esp32/ble_common.h — extern declarations shared across the ESP32 port files.
// Mirrors ports/rp2040/ble_common.h byte-for-byte except for the port comment.

#ifndef PICORUBY_BLE_ESP32_COMMON_H
#define PICORUBY_BLE_ESP32_COMMON_H

#include "btstack.h"

#ifdef __cplusplus
extern "C" {
#endif

extern hci_con_handle_t con_handle;

#ifdef __cplusplus
}
#endif

#endif // PICORUBY_BLE_ESP32_COMMON_H
```

- [ ] **Step 3: Verify**

```
Run: ls -la /Users/bash/dev/src/github.com/picoruby/picoruby/mrbgems/picoruby-ble/ports/esp32/
Report.
```

Expected: directory exists with `ble_common.h`.

### Task 1.2: Create btstack_owner.c — FreeRTOS task lifecycle

**Background:** The RP2040 port assumes BTstack is already initialized by Pico SDK at `BLE_init()` time. ESP32 has no equivalent — *we* own the task. This file centralizes that ownership so `BLE_init()` can stay a thin wrapper.

**Files:**
- Create: `/Users/bash/dev/src/github.com/picoruby/picoruby/mrbgems/picoruby-ble/ports/esp32/btstack_owner.h`
- Create: `/Users/bash/dev/src/github.com/picoruby/picoruby/mrbgems/picoruby-ble/ports/esp32/btstack_owner.c`

- [ ] **Step 1: Header**

```c
// ports/esp32/btstack_owner.h
#ifndef PICORUBY_BLE_ESP32_BTSTACK_OWNER_H
#define PICORUBY_BLE_ESP32_BTSTACK_OWNER_H

#ifdef __cplusplus
extern "C" {
#endif

// Idempotent. On first call, spawns a FreeRTOS task that runs btstack_init()
// followed by btstack_run_loop_execute(). Subsequent calls return immediately.
//
// Must be called before any l2cap_init / sm_init / att_server_init because
// btstack_init wires up the run loop, HCI transport, and TLV bonding store.
void picoruby_btstack_ensure_started(void);

#ifdef __cplusplus
}
#endif

#endif
```

- [ ] **Step 2: Implementation**

```c
// ports/esp32/btstack_owner.c
#include "btstack_owner.h"
#include "btstack.h"
#include "btstack_run_loop_freertos.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/semphr.h"
#include "esp_log.h"

static const char *TAG = "picoruby-ble";

static SemaphoreHandle_t init_done_sem = NULL;

static void btstack_task(void *param) {
  (void)param;
  ESP_LOGI(TAG, "btstack_task starting");
  btstack_init();
  // Signal the caller that BTstack is initialized and the run loop is about
  // to execute. After this point the caller may safely call l2cap_init etc.
  xSemaphoreGive(init_done_sem);
  btstack_run_loop_execute();   // blocks
  vTaskDelete(NULL);            // unreachable
}

void picoruby_btstack_ensure_started(void) {
  static bool started = false;
  if (started) return;
  started = true;
  init_done_sem = xSemaphoreCreateBinary();
  xTaskCreate(btstack_task, "btstack", 8192, NULL, 5, NULL);
  // Block the caller until btstack_init has completed. Without this, the
  // caller may call l2cap_init before btstack_run_loop is wired up.
  xSemaphoreTake(init_done_sem, portMAX_DELAY);
  ESP_LOGI(TAG, "BTstack ready");
}
```

- [ ] **Step 3: Verify**

```
Run: ls /Users/bash/dev/src/github.com/picoruby/picoruby/mrbgems/picoruby-ble/ports/esp32/
Report file list.
```

Expected: `ble_common.h`, `btstack_owner.h`, `btstack_owner.c`.

### Task 1.3: Create ports/esp32/ble.c

**Files:**
- Create: `/Users/bash/dev/src/github.com/picoruby/picoruby/mrbgems/picoruby-ble/ports/esp32/ble.c`

- [ ] **Step 1: Read RP2040 ble.c**

```
Run: cat /Users/bash/dev/src/github.com/picoruby/picoruby/mrbgems/picoruby-ble/ports/rp2040/ble.c
Report contents (full file, ~250 lines).
```

- [ ] **Step 2: Create esp32 ble.c — copy with the spec-documented diff applied**

Apply these changes to the RP2040 source:

1. **Delete** the three Pico SDK includes:
   ```c
   #include "pico/cyw43_arch.h"
   #include "pico/btstack_cyw43.h"
   #include "pico/stdlib.h"
   ```

2. **Add** at top:
   ```c
   #include "btstack_owner.h"
   ```

3. **Delete** the entire `blink_led()` function (the unused debug helper that uses `cyw43_arch_gpio_put` and `sleep_ms`).

4. **Modify** `BLE_init()` — at the top of the function body, before `l2cap_init()`, add:
   ```c
   picoruby_btstack_ensure_started();
   ```

5. Keep all other code byte-for-byte from the RP2040 source.

The resulting file should be ~225 lines (250 original − 7 Pico SDK includes − 11 blink_led lines + 1 add line + 1 add line ≈ 225).

Write the file with the modifications above. Use the RP2040 source content verbatim except for points 1–4.

- [ ] **Step 3: Verify line count is in expected range**

```
Run: wc -l /Users/bash/dev/src/github.com/picoruby/picoruby/mrbgems/picoruby-ble/ports/esp32/ble.c
Report line count.
```

Expected: 220–235.

- [ ] **Step 4: Verify no Pico SDK references remain**

```
Run: grep -nE "pico/|cyw43|sleep_ms" /Users/bash/dev/src/github.com/picoruby/picoruby/mrbgems/picoruby-ble/ports/esp32/ble.c
Report matches.
```

Expected: zero matches.

### Task 1.4: Create ports/esp32/ble_peripheral.c and ble_central.c

**Files:**
- Create: `/Users/bash/dev/src/github.com/picoruby/picoruby/mrbgems/picoruby-ble/ports/esp32/ble_peripheral.c`
- Create: `/Users/bash/dev/src/github.com/picoruby/picoruby/mrbgems/picoruby-ble/ports/esp32/ble_central.c`

- [ ] **Step 1: Read RP2040 versions**

```
Run:
  cat /Users/bash/dev/src/github.com/picoruby/picoruby/mrbgems/picoruby-ble/ports/rp2040/ble_peripheral.c
  cat /Users/bash/dev/src/github.com/picoruby/picoruby/mrbgems/picoruby-ble/ports/rp2040/ble_central.c
Report each file in full.
```

- [ ] **Step 2: Create ports/esp32/ble_peripheral.c**

Copy verbatim from rp2040 version, then **delete** any Pico SDK includes (`pico/cyw43_arch.h`, `pico/btstack_cyw43.h`, `pico/stdlib.h`). All function bodies stay unchanged because they call only BTstack pure API (`gap_advertisements_set_*`, `gap_advertisements_enable`, `att_server_notify`, `att_server_request_can_send_now_event`).

- [ ] **Step 3: Create ports/esp32/ble_central.c**

Same procedure as Step 2 for `ble_central.c`.

- [ ] **Step 4: Verify both files**

```
Run:
  wc -l /Users/bash/dev/src/github.com/picoruby/picoruby/mrbgems/picoruby-ble/ports/esp32/ble_peripheral.c
  wc -l /Users/bash/dev/src/github.com/picoruby/picoruby/mrbgems/picoruby-ble/ports/esp32/ble_central.c
  grep -nE "pico/|cyw43|sleep_ms" /Users/bash/dev/src/github.com/picoruby/picoruby/mrbgems/picoruby-ble/ports/esp32/ble_*.c
Report.
```

Expected: ble_peripheral.c around 45 lines, ble_central.c around 46 lines, zero Pico SDK matches.

### Task 1.5: Modify mrbgem.rake — platform branching

**Files:**
- Modify: `/Users/bash/dev/src/github.com/picoruby/picoruby/mrbgems/picoruby-ble/mrbgem.rake`

- [ ] **Step 1: Read current mrbgem.rake**

```
Run: cat /Users/bash/dev/src/github.com/picoruby/picoruby/mrbgems/picoruby-ble/mrbgem.rake
Report contents.
```

- [ ] **Step 2: Inspect how other gems detect ESP32 platform**

The picoruby tree already builds different platforms (host, RP2040, ESP32). Find how an existing dual-platform gem branches:

```
Run: grep -rln "esp32\|ESP32\|xtensa-esp" /Users/bash/dev/src/github.com/picoruby/picoruby/mrbgems/*/mrbgem.rake | head -5
Then for one of those files: cat <path>
Report up to two examples.
```

Expected: at least one gem (e.g., `picoruby-machine`, `picoruby-spi`, or similar) demonstrates platform detection. Use the same idiom (likely `build.toolchains` inspection or a constant set by the build_config).

- [ ] **Step 3: Edit mrbgem.rake**

Replace the file with:

```ruby
MRuby::Gem::Specification.new('picoruby-ble') do |spec|
  spec.license = 'MIT'
  spec.author  = 'HASUMI Hitoshi (port maintained by bash0C7)'
  spec.summary = 'BLE class — peripheral / central / broadcaster / observer'

  spec.add_dependency 'picoruby-mbedtls'

  # Platform detection. The convention used by other dual-platform gems in
  # this tree is to inspect the build name. RP2040 build is named
  # 'r2p2-cortex-m0plus' and ESP32 build is 'r2p2-xtensa-esp-picoruby'.
  case build.name
  when /rp2040|cortex-m0plus|cortex-m33/
    spec.add_dependency 'picoruby-cyw43'
    spec.cc.files << "#{dir}/ports/rp2040/ble.c"
    spec.cc.files << "#{dir}/ports/rp2040/ble_peripheral.c"
    spec.cc.files << "#{dir}/ports/rp2040/ble_central.c"
    spec.cc.include_paths << "#{dir}/ports/rp2040"
  when /xtensa-esp|esp32/
    spec.cc.files << "#{dir}/ports/esp32/ble.c"
    spec.cc.files << "#{dir}/ports/esp32/ble_peripheral.c"
    spec.cc.files << "#{dir}/ports/esp32/ble_central.c"
    spec.cc.files << "#{dir}/ports/esp32/btstack_owner.c"
    spec.cc.include_paths << "#{dir}/ports/esp32"
    # BTstack include paths are provided by the R2P2-ESP32 'btstack' idf component.
  else
    raise "picoruby-ble: unsupported build target '#{build.name}'"
  end

  spec.cc.include_paths << "#{dir}/include"
end
```

If the build name detection idiom found in Step 2 differs from what's shown above (e.g., a different constant like `MRuby::PICORUBY_PLATFORM` is conventional), substitute that idiom.

- [ ] **Step 4: Verify edit**

```
Run: cat /Users/bash/dev/src/github.com/picoruby/picoruby/mrbgems/picoruby-ble/mrbgem.rake
Report.
```

### Task 1.6: Enable picoruby-ble in xtensa-esp-picoruby.rb

**Files:**
- Modify: `/Users/bash/dev/src/github.com/bash0C7/R2P2-ESP32/components/picoruby-esp32/build_config/xtensa-esp-picoruby.rb`

- [ ] **Step 1: Read current build_config**

```
Run: cat /Users/bash/dev/src/github.com/bash0C7/R2P2-ESP32/components/picoruby-esp32/build_config/xtensa-esp-picoruby.rb
Report contents.
```

- [ ] **Step 2: Add picoruby-ble + picoruby-ble-uart entries**

Find the section listing `conf.gem gemdir: '...'` lines. Append (after the existing list, before any closing block):

```ruby
  conf.gem gemdir: "#{ROOT}/mrbgems/picoruby-ble"
  conf.gem gemdir: "#{ROOT}/mrbgems/picoruby-ble-uart"
```

(Use whatever the existing convention is for the picoruby root path constant. If existing gems use a literal path like `"/Users/bash/dev/src/github.com/picoruby/picoruby/mrbgems/..."`, match that.)

- [ ] **Step 3: Verify edit**

```
Run: grep -n "picoruby-ble" /Users/bash/dev/src/github.com/bash0C7/R2P2-ESP32/components/picoruby-esp32/build_config/xtensa-esp-picoruby.rb
Report matching lines.
```

Expected: 2 lines (picoruby-ble, picoruby-ble-uart).

### Task 1.7: Disable Phase 0 smoke

**Files:**
- Modify: `/Users/bash/dev/src/github.com/bash0C7/R2P2-ESP32/sdkconfigs/bt_btstack`

- [ ] **Step 1: Edit fragment to set CONFIG_BTSTACK_SMOKE=n**

Use Edit tool to replace
```
CONFIG_BTSTACK_SMOKE=y
```
with
```
CONFIG_BTSTACK_SMOKE=n
```

- [ ] **Step 2: Verify**

```
Run: grep BTSTACK_SMOKE /Users/bash/dev/src/github.com/bash0C7/R2P2-ESP32/sdkconfigs/bt_btstack
Report.
```

Expected: `CONFIG_BTSTACK_SMOKE=n`.

### Task 1.8: r2p2:setup (gem list changed)

**Files:** none

- [ ] **Step 1: Run setup via subagent**

Delegate to subagent (general-purpose, model haiku, **timeout 1500000ms** — full setup may take 15–25 minutes when adding new gems):
```
Run from /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby:
  rake r2p2:setup
Report exit code and any line containing "error" / "ERROR" / "LoadError" / "BLE" / "btstack" / "compilation".
```

Pass criteria: exit code 0. Verify `picoruby-ble` and `picoruby-ble-uart` appear in the build's prebuilt gem list.

- [ ] **Step 2: Verify gems are registered**

Delegate to subagent (general-purpose):
```
Run: grep -E "ble|btstack" /Users/bash/dev/src/github.com/bash0C7/R2P2-ESP32/components/picoruby-esp32/picoruby/build/esp32-picoruby/mrbgems/picogem_init.c
Report matching lines.
```

Expected: lines referencing `ble` and `ble-uart` modules in the static gem list.

### Task 1.9: Build (Phase 1)

**Files:** none

- [ ] **Step 1: Build via subagent**

Delegate to subagent (general-purpose, model haiku, timeout 600000ms):
```
Run from /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby:
  rake r2p2:build
Report exit code and last 30 lines + any error/warning lines.
```

Pass criteria: exit code 0. Common Phase 1 build failures:

| Symptom | Likely fix |
|---|---|
| `unknown type name 'hci_con_handle_t'` | Missing btstack include in include_paths — re-check mrbgem.rake (Task 1.5) |
| `multiple definition of 'btstack_main'` | Phase 0 smoke not gated off — re-check Task 1.7 |
| `undefined reference to 'BLE_*'` | mrbgem.rake didn't add the port .c files — re-check Step 3 of Task 1.5 |
| `LoadError: cannot load such file -- ble` | Gem registration issue — re-check Task 1.6 / 1.8 picogem_init.c grep |

### Task 1.10: Flash and verify Phase 0 smoke is silent

**Files:** none

- [ ] **Step 1: Flash via subagent**

Delegate to subagent (general-purpose, model haiku, timeout 600000ms):
```
Run from /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby:
  rake r2p2:flash
Report exit code and last 20 lines.
```

- [ ] **Step 2: Human reset**

Hand off: "Please press the reset button on the CoreS3 and wait 10 seconds."

- [ ] **Step 3: Verify Phase 0 smoke is OFF**

Hand off: "In Chrome chrome://bluetooth-internals#devices, scan again. The 'StackChan-bts' device should NOT appear (because the smoke is now disabled)."

If it appears, Task 1.7 was not applied — verify and re-flash.

### Task 1.11: Write minimal BLE smoke .rb

**Files:**
- Create: `/Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/mrbgems/picoruby-stackchan-protocol/examples/ble_smoke.rb`

- [ ] **Step 1: Write the file**

```ruby
# examples/ble_smoke.rb — Phase 1 picoruby-ble smoke
# Advertises 'StackChan-PicoRuby' for 60 seconds then exits so upload remains race-free.

require 'ble'

# Minimal GATT profile: GAP service only with custom device name.
# BLE::GattDatabase builds the wire-format profile_data array.
gatt = BLE::GattDatabase.new do |db|
  db.add_service(0x1800) do |svc|       # GAP Service
    svc.add_characteristic(0x2A00,       # Device Name
                           properties: [:read],
                           value: 'StackChan-PicoRuby')
  end
end

ble = BLE.new(:peripheral, gatt.profile_data)

# Build advertise data: flags + complete local name.
adv = BLE::AdvertisingData.build do |b|
  b.flags(:le_general_discoverable, :br_edr_not_supported)
  b.local_name('StackChan-PicoRuby')
end

ble.peripheral_advertise(adv)
puts "[ble_smoke] advertising as 'StackChan-PicoRuby' for 60s"
60.times do |i|
  ble.start(100)   # poll BTstack for 100ms; returns control to Ruby
  print '.' if i % 10 == 0
end
puts
puts '[ble_smoke] done'
```

**Note on API exact spelling:** Verify the API method names from `mrblib/ble.rb`, `mrblib/ble_advertising_data.rb`, `mrblib/ble_gatt_database.rb` in the picoruby-ble gem before writing — the spec listed `BLE::GattDatabase` and `BLE::AdvertisingData.build` but check the actual constructor. If the script doesn't match the gem's API, the API spelling wins (correct the script).

- [ ] **Step 2: Verify**

```
Run: cat /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/mrbgems/picoruby-stackchan-protocol/examples/ble_smoke.rb
Report.
```

### Task 1.12: Upload + verify advertise from Chrome

**Files:** none

- [ ] **Step 1: Upload via subagent**

Delegate to subagent (general-purpose, model haiku, timeout 120000ms):
```
Run from /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby:
  rake r2p2:upload SRC=mrbgems/picoruby-stackchan-protocol/examples/ble_smoke.rb
Report exit code and last 10 lines.
```

If upload fails with `FILE_ACK got nil`, hand off to human per the project recovery procedure: "Please open monitor (`cd ../../bash0C7/R2P2-ESP32 && rake monitor`) and run `rm /home/app.rb`, then Ctrl-]. I'll re-run upload."

- [ ] **Step 2: Human reset**

Hand off: "Please press reset on the CoreS3 and wait 5 seconds."

- [ ] **Step 3: Verify Chrome sees 'StackChan-PicoRuby'**

Hand off: "In Chrome chrome://bluetooth-internals#devices, scan. Within 30 seconds you should see 'StackChan-PicoRuby'. Report whether it appears AND whether the previous 'StackChan-bts' is absent."

Pass criteria: 'StackChan-PicoRuby' appears, 'StackChan-bts' absent.

If 'StackChan-PicoRuby' does not appear:
- Have human run `rake monitor` in another terminal
- Look for Ruby exception logs (`LoadError`, `NameError`, `NoMethodError`)
- Look for `[picoruby-ble] BTstack ready` from btstack_owner.c
- If no Ruby errors and no BTstack log, BLE_init was never called → check ble_smoke.rb syntax / API names

### Task 1.13: Commit Phase 1

**Files:** all of Phase 1

- [ ] **Step 1: Commit picoruby tree (the new ports/esp32 + mrbgem.rake)**

Delegate to subagent (general-purpose):
```
In /Users/bash/dev/src/github.com/picoruby/picoruby:
  git add mrbgems/picoruby-ble/ports/esp32/ mrbgems/picoruby-ble/mrbgem.rake
  git status --short
  git diff --cached --stat
Report.
```

Then:
```
git commit -m "$(cat <<'EOF'
feat(picoruby-ble): add ports/esp32 backed by BTstack VHCI

Port is 96% line-for-line copy of ports/rp2040/ with Pico SDK includes
removed and an explicit BTstack FreeRTOS task owner added (the RP2040
port relies on Pico SDK to bring up BTstack; on ESP32 we own the task).

mrbgem.rake branches on build.name to select rp2040 vs esp32 sources.
ESP32 builds depend on the BTstack idf component provided by R2P2-ESP32.

Verified on M5Stack CoreS3 + ESP-IDF v5.4: PicoRuby script
'BLE.new(:peripheral, ...).peripheral_advertise(...)' results in the
device appearing in Chrome chrome://bluetooth-internals.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 2: Commit R2P2-ESP32 changes (build_config + smoke gate)**

Delegate to subagent (general-purpose):
```
In /Users/bash/dev/src/github.com/bash0C7/R2P2-ESP32:
  git add components/picoruby-esp32/build_config/xtensa-esp-picoruby.rb sdkconfigs/bt_btstack
  git status --short
Report.
```

Then:
```
git commit -m "$(cat <<'EOF'
feat(ble): enable picoruby-ble + picoruby-ble-uart, disable Phase 0 smoke

Adds the two BLE-related picoruby gems to the build_config and turns
off CONFIG_BTSTACK_SMOKE so picoruby-ble owns the BTstack lifecycle.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 3: Commit stackchan-picoruby smoke .rb**

Delegate to subagent (general-purpose):
```
In /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby:
  git add mrbgems/picoruby-stackchan-protocol/examples/ble_smoke.rb
  git status --short
Report.
```

Then:
```
git commit -m "$(cat <<'EOF'
feat(stackchan-protocol): add ble_smoke.rb advertising sample

Phase 1 PicoRuby smoke — BLE.new(:peripheral) advertises
'StackChan-PicoRuby' for 60 seconds and exits, keeping app.rb
upload-friendly.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 2: NUS + stackchan-protocol frame bring-up

**Goal of Phase 2:** End-to-end "Mac → BLE → StackChan, face changes" using the existing stackchan-protocol frame format ridden on Nordic UART Service (NUS).

**Deliverable:**
1. PicoRuby `examples/avatar.rb` runs a dispatcher loop fed from BLE NUS RX, sends events back via BLE NUS TX.
2. Mac Ruby script `pc/stackchan-protocol/exe/stackchan-control --transport=ble` sends a face change frame and the StackChan face changes.
3. Browser HTML demo page (Web Bluetooth) does the same.

**Risk bucket:** Lowest. PicoRuby BLE is proven (Phase 1), NUS is purely a Ruby gem (`picoruby-ble-uart` mrblib), and the frame protocol is unchanged byte-for-byte.

### File Structure (Phase 2)

| File | Action | Responsibility |
|---|---|---|
| `stackchan-picoruby/pc/stackchan-protocol/lib/stackchan_protocol/transport.rb` | **Create** | Abstract transport interface (write_bytes / read_bytes / on_event) |
| `stackchan-picoruby/pc/stackchan-protocol/lib/stackchan_protocol/transports/uart.rb` | **Create** | Existing USB-serial transport extracted to a class |
| `stackchan-picoruby/pc/stackchan-protocol/lib/stackchan_protocol/transports/ble.rb` | **Create** | New: NUS via core_bluetooth gem |
| `stackchan-picoruby/pc/stackchan-protocol/lib/stackchan_protocol/frame_writer.rb` | **Modify** | Accept any transport object, no longer assumes UART |
| `stackchan-picoruby/pc/stackchan-protocol/exe/stackchan-control` | **Modify** | Add `--transport=ble|uart` CLI option |
| `stackchan-picoruby/pc/stackchan-protocol/test/transport_uart_test.rb` | **Create** | TDD: existing UART transport behavior preserved |
| `stackchan-picoruby/pc/stackchan-protocol/test/transport_ble_test.rb` | **Create** | TDD: BLE transport with mock CoreBluetooth |
| `stackchan-picoruby/pc/stackchan-protocol/Gemfile` | **Modify** | Add `core_bluetooth` gem |
| `stackchan-picoruby/mrbgems/picoruby-stackchan-protocol/mrblib/dispatcher.rb` | **Modify** | Read from any IO-like (UART or BLE::UART), not just UART. Done by accepting an `io` constructor arg |
| `stackchan-picoruby/mrbgems/picoruby-stackchan-protocol/examples/avatar.rb` | **Create** | Production app: BLE NUS + Dispatcher + Face/LED handlers |
| `stackchan-picoruby/web/stackchan-control.html` | **Create** | Web Bluetooth demo: NUS write + notify subscribe + face buttons |

### Task 2.1: TDD — Extract Transport abstraction (UART side)

**Files:**
- Create: `/Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/pc/stackchan-protocol/test/transport_uart_test.rb`
- Create: `/Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/pc/stackchan-protocol/lib/stackchan_protocol/transport.rb`
- Create: `/Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/pc/stackchan-protocol/lib/stackchan_protocol/transports/uart.rb`

- [ ] **Step 1: Write failing test for UART transport**

```ruby
# test/transport_uart_test.rb
require 'test/unit'
require 'stringio'
require_relative '../lib/stackchan_protocol/transports/uart'

class TransportUartTest < Test::Unit::TestCase
  def test_write_bytes_writes_to_underlying_io
    io = StringIO.new(+'')
    transport = StackchanProtocol::Transports::Uart.new(io)
    transport.write_bytes("\x02\x00\x05F\xAB\xCD".b)
    assert_equal "\x02\x00\x05F\xAB\xCD".b, io.string
  end

  def test_read_bytes_reads_from_underlying_io
    io = StringIO.new("\x06hello!".b)
    transport = StackchanProtocol::Transports::Uart.new(io)
    assert_equal "\x06hello!".b, transport.read_bytes(7)
  end
end
```

- [ ] **Step 2: Run test, verify it fails**

Delegate to subagent (general-purpose):
```
Run from /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/pc/stackchan-protocol:
  bundle exec rake test TEST=test/transport_uart_test.rb
Report exit code and which assertion failed.
```

Expected: failure with "cannot load such file -- stackchan_protocol/transports/uart".

- [ ] **Step 3: Create the abstract transport interface**

```ruby
# lib/stackchan_protocol/transport.rb — abstract interface for frame transports.
module StackchanProtocol
  class Transport
    # Write raw bytes to the device. Override in subclasses.
    def write_bytes(bytes); raise NotImplementedError; end

    # Read up to n bytes from the device with optional timeout in seconds.
    # Returns the bytes read (may be fewer than n on timeout).
    def read_bytes(n, timeout: nil); raise NotImplementedError; end

    # Optional close handle.
    def close; end
  end
end
```

- [ ] **Step 4: Create UART transport**

```ruby
# lib/stackchan_protocol/transports/uart.rb — wraps any IO-like object.
require_relative '../transport'

module StackchanProtocol
  module Transports
    class Uart < StackchanProtocol::Transport
      def initialize(io)
        @io = io
      end

      def write_bytes(bytes)
        @io.write(bytes)
      end

      def read_bytes(n, timeout: nil)
        # Caller is responsible for setting non-blocking timeout on the underlying IO if needed.
        @io.read(n)
      end

      def close
        @io.close if @io.respond_to?(:close) && !@io.closed?
      end
    end
  end
end
```

- [ ] **Step 5: Run test, verify it passes**

Delegate to subagent:
```
Run: bundle exec rake test TEST=test/transport_uart_test.rb
Report exit code, test count, assertion count.
```

Expected: 0 failures, 0 errors, 2 tests, 2 assertions.

- [ ] **Step 6: Commit**

Delegate to subagent (general-purpose):
```
In /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby:
  git add pc/stackchan-protocol/lib/stackchan_protocol/transport.rb \
          pc/stackchan-protocol/lib/stackchan_protocol/transports/uart.rb \
          pc/stackchan-protocol/test/transport_uart_test.rb
  git commit -m "$(cat <<'EOF'
refactor(pc/stackchan-protocol): extract Transport abstraction with UART impl

Prepares for BLE transport in upcoming task. Existing UART path is preserved
behind StackchanProtocol::Transports::Uart wrapping any IO-like object.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 2.2: TDD — BLE transport with mocked CoreBluetooth

**Files:**
- Modify: `/Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/pc/stackchan-protocol/Gemfile`
- Create: `/Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/pc/stackchan-protocol/test/transport_ble_test.rb`
- Create: `/Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/pc/stackchan-protocol/lib/stackchan_protocol/transports/ble.rb`

- [ ] **Step 1: Add core_bluetooth gem to Gemfile**

Read current Gemfile:
```
Run: cat /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/pc/stackchan-protocol/Gemfile
Report.
```

Append:
```ruby
gem 'core_bluetooth', '~> 0.2'   # Mac CoreBluetooth FFI binding
```

Note: `core_bluetooth` is the most actively maintained Ruby gem for CoreBluetooth at time of writing. If a newer/different gem is preferred (e.g., `rb-corebluetooth`, `cocoa-bluetooth`), substitute and adjust the transport implementation in Step 4.

- [ ] **Step 2: Run bundle install**

Delegate to subagent (general-purpose):
```
Run from /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/pc/stackchan-protocol:
  bundle install
Report exit code and any gem build error.
```

- [ ] **Step 3: Write failing BLE transport test**

```ruby
# test/transport_ble_test.rb
require 'test/unit'
require_relative '../lib/stackchan_protocol/transports/ble'

class TransportBleTest < Test::Unit::TestCase
  # NUS standard UUIDs.
  NUS_SERVICE = '6e400001-b5a3-f393-e0a9-e50e24dcca9e'
  NUS_RX      = '6e400002-b5a3-f393-e0a9-e50e24dcca9e' # write
  NUS_TX      = '6e400003-b5a3-f393-e0a9-e50e24dcca9e' # notify

  # Lightweight stub that emulates the surface of core_bluetooth's
  # CharacteristicProxy for testing.
  class MockChar
    attr_reader :writes
    def initialize; @writes = []; end
    def write_value(data, type:); @writes << data; end
    def subscribe(&block); @notify_callback = block; end
    def emit_notify(bytes); @notify_callback&.call(bytes); end
  end

  def setup
    @rx = MockChar.new
    @tx = MockChar.new
    @transport = StackchanProtocol::Transports::Ble.new(rx_char: @rx, tx_char: @tx)
  end

  def test_write_bytes_invokes_write_on_rx_characteristic
    @transport.write_bytes("\x02\x00\x01F".b)
    assert_equal ["\x02\x00\x01F".b], @rx.writes
  end

  def test_read_bytes_consumes_notifications_in_order
    @tx.emit_notify("\x01\x02\x03".b)
    @tx.emit_notify("\x04\x05".b)
    assert_equal "\x01\x02\x03\x04\x05".b, @transport.read_bytes(5)
  end

  def test_read_bytes_returns_partial_data_on_timeout
    @tx.emit_notify("\x01\x02".b)
    result = @transport.read_bytes(10, timeout: 0.05)
    assert_equal "\x01\x02".b, result
  end
end
```

- [ ] **Step 4: Run test, verify it fails**

```
Run: bundle exec rake test TEST=test/transport_ble_test.rb
Report.
```

Expected: failure ("cannot load such file -- stackchan_protocol/transports/ble").

- [ ] **Step 5: Implement BLE transport**

```ruby
# lib/stackchan_protocol/transports/ble.rb — Mac CoreBluetooth NUS transport.
require_relative '../transport'

module StackchanProtocol
  module Transports
    # Wraps a connected NUS service. Caller is responsible for the connect
    # lifecycle (typically through Connector below). Once constructed, the
    # transport reads from the TX (notify) characteristic and writes to the
    # RX (write) characteristic.
    class Ble < StackchanProtocol::Transport
      NUS_SERVICE = '6e400001-b5a3-f393-e0a9-e50e24dcca9e'
      NUS_RX      = '6e400002-b5a3-f393-e0a9-e50e24dcca9e'
      NUS_TX      = '6e400003-b5a3-f393-e0a9-e50e24dcca9e'

      def initialize(rx_char:, tx_char:)
        @rx_char = rx_char
        @tx_char = tx_char
        @rx_buffer = String.new(encoding: 'BINARY')
        @rx_mutex  = Mutex.new
        @rx_cond   = ConditionVariable.new
        @tx_char.subscribe do |bytes|
          @rx_mutex.synchronize do
            @rx_buffer << bytes.b
            @rx_cond.broadcast
          end
        end
      end

      def write_bytes(bytes)
        # NUS write-without-response is the typical mode for stream protocols
        # because it skips the per-packet ACK round-trip. CoreBluetooth uses
        # :write_without_response or :with_response symbols.
        @rx_char.write_value(bytes, type: :write_without_response)
      end

      def read_bytes(n, timeout: nil)
        deadline = timeout && (Time.now + timeout)
        @rx_mutex.synchronize do
          loop do
            return drain(n) if @rx_buffer.bytesize >= n
            return drain(@rx_buffer.bytesize) if deadline && Time.now >= deadline
            wait = deadline ? deadline - Time.now : nil
            @rx_cond.wait(@rx_mutex, wait)
          end
        end
      end

      private

      def drain(n)
        return ''.b if n.zero?
        out = @rx_buffer.byteslice(0, n)
        @rx_buffer = @rx_buffer.byteslice(n..-1) || ''.b
        out
      end
    end
  end
end
```

- [ ] **Step 6: Run test, verify it passes**

```
Run: bundle exec rake test TEST=test/transport_ble_test.rb
Report.
```

Expected: 0 failures, 0 errors, 3 tests.

- [ ] **Step 7: Commit**

```
In /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby:
  git add pc/stackchan-protocol/Gemfile pc/stackchan-protocol/Gemfile.lock pc/stackchan-protocol/lib/stackchan_protocol/transports/ble.rb pc/stackchan-protocol/test/transport_ble_test.rb
  git commit -m "$(cat <<'EOF'
feat(pc/stackchan-protocol): add BLE NUS transport via core_bluetooth

Reads from TX notify characteristic into a thread-safe buffer; writes
go to the RX characteristic with write-without-response. read_bytes
honors an optional timeout for partial-buffer returns.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 2.3: Add BLE Connector helper (Mac side)

**Files:**
- Create: `/Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/pc/stackchan-protocol/lib/stackchan_protocol/transports/ble_connector.rb`

This task is not TDD because CoreBluetooth scan/connect is intrinsically async and OS-level — we can only smoke it on real hardware. The implementation is straightforward driver code.

- [ ] **Step 1: Implement connector**

```ruby
# lib/stackchan_protocol/transports/ble_connector.rb — Connect to a StackChan over NUS.
require 'core_bluetooth'
require_relative 'ble'

module StackchanProtocol
  module Transports
    class BleConnector
      # Scans for the named device, connects, discovers NUS, and returns a
      # ready-to-use StackchanProtocol::Transports::Ble.
      #
      # name_pattern: a String exact match or Regexp.
      # timeout: scan + connect timeout in seconds.
      def self.connect(name_pattern: 'StackChan-PicoRuby', timeout: 30)
        manager = CoreBluetooth::CentralManager.new
        manager.wait_for_state(:powered_on, timeout: 5)
        peripheral = manager.scan_for(name_pattern, timeout: timeout)
        raise "No StackChan device found in #{timeout}s" unless peripheral
        peripheral.connect(timeout: timeout)
        nus_service = peripheral.discover_service(Ble::NUS_SERVICE, timeout: 10)
        raise 'NUS service not found on device' unless nus_service
        rx = nus_service.discover_characteristic(Ble::NUS_RX, timeout: 5)
        tx = nus_service.discover_characteristic(Ble::NUS_TX, timeout: 5)
        raise 'NUS RX/TX characteristic missing' unless rx && tx
        Ble.new(rx_char: rx, tx_char: tx)
      end
    end
  end
end
```

**Note:** The `core_bluetooth` API surface above (`CentralManager.new`, `scan_for`, `peripheral.connect`, `discover_service`, etc.) is the most idiomatic shape — verify against the gem's actual API before this task is executed and adjust method names. If the gem in use has a callback-driven API rather than synchronous, wrap that in a Future/Promise to preserve the synchronous return contract above.

- [ ] **Step 2: Smoke (real hardware required, no unit test)**

Hand off to human: "On the Mac, with the StackChan running ble_smoke.rb, run:
```
cd pc/stackchan-protocol && bundle exec ruby -Ilib -e \"require 'stackchan_protocol/transports/ble_connector'; t = StackchanProtocol::Transports::BleConnector.connect; puts 'connected'; t.close\"
```
Report whether 'connected' prints."

If it errors, capture exception text and address (likely a `core_bluetooth` API surface mismatch — adjust connector and retry).

- [ ] **Step 3: Commit (after smoke passes)**

```
git add pc/stackchan-protocol/lib/stackchan_protocol/transports/ble_connector.rb
git commit -m "$(cat <<'EOF'
feat(pc/stackchan-protocol): add Mac BLE NUS connector

Convenience wrapper around core_bluetooth that scans, connects, and
discovers the NUS service+characteristics, returning a ready-to-use
StackchanProtocol::Transports::Ble.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 2.4: Wire transport into FrameWriter

**Files:**
- Modify: `/Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/pc/stackchan-protocol/lib/stackchan_protocol/frame_writer.rb`
- Create/Modify: `/Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/pc/stackchan-protocol/test/frame_writer_test.rb`

- [ ] **Step 1: Read current FrameWriter**

```
Run: cat /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/pc/stackchan-protocol/lib/stackchan_protocol/frame_writer.rb
Report.
```

- [ ] **Step 2: Write failing test**

```ruby
# test/frame_writer_test.rb (or extend existing)
require 'test/unit'
require_relative '../lib/stackchan_protocol/frame_writer'
require_relative '../lib/stackchan_protocol/transports/uart'
require 'stringio'

class FrameWriterTest < Test::Unit::TestCase
  def test_send_frame_through_transport
    io = StringIO.new(+'')
    transport = StackchanProtocol::Transports::Uart.new(io)
    writer = StackchanProtocol::FrameWriter.new(transport)
    writer.send_face(:happy)
    refute_empty io.string, 'frame should have been written through transport'
    # First byte must be STX
    assert_equal 0x02, io.string.bytes[0]
  end
end
```

- [ ] **Step 3: Run test, verify failure mode**

If FrameWriter currently takes an IO directly and constructs frames with STX, the test may still pass if `Uart#write_bytes` delegates to `io.write`. If it fails with constructor signature mismatch, that confirms refactoring is needed.

- [ ] **Step 4: Refactor FrameWriter to accept any transport**

Edit `frame_writer.rb` so the constructor takes a transport object that responds to `write_bytes`. Replace any direct IO calls with `@transport.write_bytes(bytes)`.

- [ ] **Step 5: Run test, verify pass**

```
Run: bundle exec rake test TEST=test/frame_writer_test.rb
Report.
```

- [ ] **Step 6: Commit**

```
git add pc/stackchan-protocol/lib/stackchan_protocol/frame_writer.rb pc/stackchan-protocol/test/frame_writer_test.rb
git commit -m "$(cat <<'EOF'
refactor(pc/stackchan-protocol): FrameWriter accepts any Transport

Removes implicit IO assumption so the same writer works for UART
(USB-serial) and BLE (NUS via CoreBluetooth) transports.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 2.5: Add --transport=ble|uart option to stackchan-control CLI

**Files:**
- Modify: `/Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/pc/stackchan-protocol/exe/stackchan-control`

- [ ] **Step 1: Read current CLI**

```
Run: cat /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/pc/stackchan-protocol/exe/stackchan-control
Report.
```

- [ ] **Step 2: Add transport option**

Modify the OptionParser block to add:

```ruby
options[:transport] = :uart  # default

opts.on('--transport=TYPE', [:uart, :ble], 'Transport: uart (default) or ble') do |t|
  options[:transport] = t
end
```

Then where the transport is constructed, branch:

```ruby
require_relative '../lib/stackchan_protocol/transports/uart'

transport = case options[:transport]
            when :uart
              io = open_serial_port(options[:port], baud: options[:baud])
              StackchanProtocol::Transports::Uart.new(io)
            when :ble
              require_relative '../lib/stackchan_protocol/transports/ble_connector'
              StackchanProtocol::Transports::BleConnector.connect(
                name_pattern: options[:device_name] || 'StackChan-PicoRuby'
              )
            end

writer = StackchanProtocol::FrameWriter.new(transport)
```

The exact integration depends on the current CLI structure — preserve all existing flags and verbs (face, led, raw, combo).

- [ ] **Step 3: Smoke test the CLI parses correctly**

```
Run: bundle exec ruby exe/stackchan-control --help
Report.
```

Expected: `--transport=TYPE` appears in usage, no parse error.

- [ ] **Step 4: Commit**

```
git add pc/stackchan-protocol/exe/stackchan-control
git commit -m "$(cat <<'EOF'
feat(pc/stackchan-protocol): --transport=ble|uart on stackchan-control CLI

Default remains uart (USB-serial) for backward compatibility with
existing flows. --transport=ble uses BleConnector to find a
StackChan-PicoRuby device, connect over NUS, and stream frames.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 2.6: Make Dispatcher transport-agnostic on the PicoRuby side

**Files:**
- Modify: `/Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/mrbgems/picoruby-stackchan-protocol/mrblib/dispatcher.rb`

- [ ] **Step 1: Read current Dispatcher**

```
Run: cat /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/mrbgems/picoruby-stackchan-protocol/mrblib/dispatcher.rb
Report.
```

- [ ] **Step 2: Refactor**

If the Dispatcher currently reads from `STDIN` or a UART singleton, change the constructor to take an IO-like object that responds to `read` and `write`. The BLE::UART class (from picoruby-ble-uart) provides this surface.

```ruby
# Before (illustrative):
# class Dispatcher
#   def run
#     loop { byte = STDIN.read(1); ... }
#   end
# end

# After:
class Dispatcher
  def initialize(io:, parser: FrameParser.new, handlers: {})
    @io = io
    @parser = parser
    @handlers = handlers
  end

  def run
    loop do
      byte = @io.read(1)
      next unless byte
      frame = @parser.feed(byte)
      next unless frame
      handler = @handlers[frame.cmd]
      handler&.call(frame.payload)
    end
  end
end
```

Preserve any existing exit-byte / frame-cmd handling.

- [ ] **Step 3: Run host tests**

```
Run from /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/mrbgems/picoruby-stackchan-protocol:
  bundle exec rake test
Report exit code and test count.
```

Expected: pass. If existing tests assumed STDIN, update them to pass a StringIO.

- [ ] **Step 4: Commit**

```
git add mrbgems/picoruby-stackchan-protocol/mrblib/dispatcher.rb mrbgems/picoruby-stackchan-protocol/test/
git commit -m "$(cat <<'EOF'
refactor(stackchan-protocol): Dispatcher reads from injected io

Decouples dispatcher from STDIN so it can be driven by BLE::UART
(picoruby-ble-uart) on-device. UART (USB-serial) path still works by
passing $stdin.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 2.7: Write production avatar.rb (BLE NUS dispatcher loop)

**Files:**
- Create: `/Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/mrbgems/picoruby-stackchan-protocol/examples/avatar.rb`

- [ ] **Step 1: Implementation**

```ruby
# examples/avatar.rb — Phase 2 production app
# Initializes board (LCD + LED + face), starts BLE NUS, and runs the
# stackchan-protocol Dispatcher loop reading from BLE::UART.

require 'i2c'
require 'spi'
require 'ili9342'
require 'py32-io-expander'
require 'stackchan-led'
require 'stackchan-protocol'
require 'ble'
require 'ble-uart'

# ---- Board init (AXP2101 + AW9523 + PY32; see CLAUDE.md hardware section) ----
i2c = I2C.new(unit: :ESP32_I2C0, sda_pin: 12, scl_pin: 11, frequency: 400_000)

# AXP2101 PMIC: 8 registers from upstream stackchan.cc (LCD/backlight rails)
[[0x97, 0x28], [0x69, 0x28], [0x30, 0xBC], [0x90, 0xBF],
 [0x94, 0x00], [0x95, 0x00], [0x27, 0x00], [0x99, 0x18]].each do |reg, val|
  i2c.write(0x34, reg, val)
end

# AW9523 expander: WS2812 5V rail (P0=0b00000111) + LCD reset pulse
i2c.write(0x58, 0x02, 0b00000111)
i2c.write(0x58, 0x03, 0x81); sleep_ms 20; i2c.write(0x58, 0x03, 0x83)

# PY32 IO expander: VM_EN HIGH then settle
py32 = PY32IOExpander.new(i2c)
py32.digital_write(0, true)
sleep_ms 200

# ---- Subsystem objects ----
spi = SPI.new(unit: :ESP32_SPI2, sck_pin: 36, mosi_pin: 37, miso_pin: -1)
lcd = ILI9342.new(spi: spi, dc_pin: 35, cs_pin: 3, rst_pin: 1, bl_pin: 2)
led = StackchanLed.new(py32: py32)
face = StackchanProtocol::Face.new(lcd)

# ---- BLE NUS init ----
nus_uart = BLE::UART.new(name: 'StackChan-PicoRuby')
nus_uart.start  # advertises and begins notify-loop

puts '[avatar] BLE NUS up, waiting for client'

# ---- Frame handlers ----
handlers = {
  'F' => ->(payload) { face.set(payload[0]) },                      # Face name byte
  'L' => ->(payload) { led.set_color_mode(payload[0], payload[1]) },# Color, Mode
  # 'S' (Speak) and 'T' (Text) handlers will be added once speaker /
  # text-on-LCD subsystems exist; they would call existing drivers similarly.
}

dispatcher = StackchanProtocol::Dispatcher.new(
  io: nus_uart,
  handlers: handlers
)

# ---- Run forever; exit hatch is BLE disconnect (user removes /home/app.rb to escape) ----
dispatcher.run
```

- [ ] **Step 2: Verify**

```
Run: cat /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/mrbgems/picoruby-stackchan-protocol/examples/avatar.rb | head -60
Report.
```

### Task 2.8: Upload avatar.rb and verify BLE-driven face change

**Files:** none

- [ ] **Step 1: Upload via subagent**

Delegate to subagent (general-purpose, model haiku, timeout 120000ms):
```
Run from /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby:
  rake r2p2:upload SRC=mrbgems/picoruby-stackchan-protocol/examples/avatar.rb
Report exit code.
```

Recovery if upload fails: hand off to human per project recovery procedure.

- [ ] **Step 2: Human reset, board boot**

Hand off: "Please press reset on the CoreS3, wait ~10 seconds for boot. The LCD should show the Neutral face. Confirm."

Pass: face shown, no exception logs (verify via monitor).

- [ ] **Step 3: Smoke — face change via BLE from Mac**

Delegate to subagent (general-purpose):
```
Run from /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/pc/stackchan-protocol:
  bundle exec exe/stackchan-control --transport=ble face --name=happy
Report exit code and any output.
```

Hand off to human: "After the command completes, the LCD face should change to Happy. Confirm."

Pass criteria: face changes within 5 seconds of CLI completion.

If face does not change but CLI succeeded:
- Check device monitor for received bytes log (add a `puts payload.inspect` line in the F handler temporarily)
- Verify Mac actually wrote to the NUS RX char (check `core_bluetooth` log level)

If CLI errors with `No StackChan device found`:
- Verify device is still advertising (Chrome chrome://bluetooth-internals)
- Increase `--transport=ble` scan timeout if implemented as a CLI flag
- Confirm Bluetooth is enabled in Mac System Settings

- [ ] **Step 4: Commit**

```
In /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby:
  git add mrbgems/picoruby-stackchan-protocol/examples/avatar.rb
  git commit -m "$(cat <<'EOF'
feat(stackchan-protocol): production avatar.rb on BLE NUS dispatcher

Initializes board (AXP2101 + AW9523 + PY32 + LCD + LED), starts
NUS as 'StackChan-PicoRuby', runs Dispatcher reading frames over BLE.
F (face) and L (LED) handlers wired; S (speak) and T (text) deferred
until speaker / text drivers exist.

Verified: Mac stackchan-control --transport=ble face --name=happy
changes the LCD face.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 2.9: Web Bluetooth demo HTML

**Files:**
- Create: `/Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/web/stackchan-control.html`

- [ ] **Step 1: Implementation**

```html
<!doctype html>
<meta charset="utf-8">
<title>StackChan Web BLE Control</title>
<body>
<h1>StackChan Web BLE Control</h1>
<button id="connect">Connect</button>
<div id="status">Disconnected</div>
<hr>
<button data-face="0">Neutral</button>
<button data-face="1">Happy</button>
<button data-face="2">Sad</button>

<script>
const NUS_SERVICE = '6e400001-b5a3-f393-e0a9-e50e24dcca9e';
const NUS_RX      = '6e400002-b5a3-f393-e0a9-e50e24dcca9e';
const NUS_TX      = '6e400003-b5a3-f393-e0a9-e50e24dcca9e';

let rxChar = null;

function buildFrame(cmd, payload) {
  const cmdByte = cmd.charCodeAt(0);
  const len = 1 + payload.length;
  const frame = new Uint8Array(2 + 2 + 1 + payload.length + 2);
  let i = 0;
  frame[i++] = 0x02;                       // STX
  frame[i++] = (len >> 8) & 0xff;          // length BE
  frame[i++] = len & 0xff;
  frame[i++] = cmdByte;
  for (const b of payload) frame[i++] = b;
  // CRC16 (XMODEM polynomial 0x1021, init 0)
  let crc = 0;
  for (let j = 3; j < i; j++) {
    crc ^= (frame[j] << 8);
    for (let k = 0; k < 8; k++) crc = (crc & 0x8000) ? ((crc << 1) ^ 0x1021) & 0xffff : (crc << 1) & 0xffff;
  }
  frame[i++] = (crc >> 8) & 0xff;
  frame[i++] = crc & 0xff;
  return frame.slice(0, i);
}

document.getElementById('connect').onclick = async () => {
  const status = document.getElementById('status');
  try {
    const device = await navigator.bluetooth.requestDevice({
      filters: [{ services: [NUS_SERVICE] }],
    });
    status.textContent = `Connecting to ${device.name}...`;
    const server = await device.gatt.connect();
    const svc    = await server.getPrimaryService(NUS_SERVICE);
    rxChar       = await svc.getCharacteristic(NUS_RX);
    const tx     = await svc.getCharacteristic(NUS_TX);
    await tx.startNotifications();
    tx.addEventListener('characteristicvaluechanged', (e) => {
      const v = new Uint8Array(e.target.value.buffer);
      console.log('TX notify:', Array.from(v).map(b => b.toString(16).padStart(2, '0')).join(' '));
    });
    status.textContent = `Connected to ${device.name}`;
  } catch (e) {
    status.textContent = `Error: ${e.message}`;
  }
};

document.querySelectorAll('button[data-face]').forEach((btn) => {
  btn.onclick = async () => {
    if (!rxChar) { alert('Connect first'); return; }
    const face = parseInt(btn.dataset.face);
    const frame = buildFrame('F', [face]);
    await rxChar.writeValueWithoutResponse(frame);
  };
});
</script>
</body>
```

**Note on CRC:** The frame protocol uses CRC16 — verify the polynomial / init / final XOR against `pc/stackchan-protocol/lib/stackchan_protocol/frame_writer.rb` and adjust the JS implementation to match.

- [ ] **Step 2: Verify file structure**

```
Run: ls -la /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby/web/
Report.
```

- [ ] **Step 3: Smoke — Web Bluetooth face change**

Hand off to human: "Open `web/stackchan-control.html` in Chrome (file:// or via simple HTTP server). Click Connect, select 'StackChan-PicoRuby' from the device picker, then click 'Happy'. The LCD face should change. Report results including any browser console errors."

Pass criteria: face changes within 3 seconds of button click.

- [ ] **Step 4: Commit**

```
git add web/stackchan-control.html
git commit -m "$(cat <<'EOF'
feat(web): minimal Web Bluetooth StackChan control demo

Single HTML page that connects to NUS, builds a frame with CRC, and
sends face-change commands. Demonstrates the 'Mac/Browser → BLE →
StackChan' path that motivated choosing NUS+frame as the wire format.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 2.10: Open PR (optional, defer if not ready to upstream)

picoruby-ble's new `ports/esp32/` may be valuable upstream. After Phase 2 stable:

- [ ] **Step 1: Push picoruby branch to bash0C7 fork**

(Requires creating a GitHub fork first. Ask the user before pushing.)

- [ ] **Step 2: Open draft PR upstream**

Title: `Add ports/esp32 (BTstack on ESP-IDF) for picoruby-ble`

Body should reference this plan and the spec, summarize the diff (~225 line port file mostly copied from rp2040), and note that the BTstack integration depends on an idf component provided by the consuming project (R2P2-ESP32 fork).

This task is **not required** for the BLE feature to work — it's pure community contribution. Skip if not ready.

---

## Self-Review

**Spec coverage check (against `docs/superpowers/specs/2026-05-15-ble-bringup-trace.md`):**

- §1 (BTstack ESP32 port trace): Covered by Phase 0 Tasks 0.4–0.7
- §1.3 (sdkconfig requirements): Covered by Phase 0 Task 0.2
- §1.6 (v5.4 adaptation `CONFIG_BT_CONTROLLER_ENABLED`): Included in Task 0.2 fragment
- §2 (picoruby-ble port spec): Covered by Phase 1 Tasks 1.1–1.5
- §2.5 (mrbgem.rake platform branching): Covered by Task 1.5
- §3 (StackChan official BLE — used as **anti**-pattern reference, not implemented): Acknowledged in spec §5; no plan task because user opted out of public ecosystem compat
- §4 Phase 0/1/2 staging: Mirrored exactly in plan
- §5 Protocol selection: User chose NUS + existing frame; reflected in Phase 2 Task 2.7 and 2.9
- §6 Risks (BTstack v5.4 controller API drift, run loop coordination, NVS partition size): Addressed in Phase 0 Task 0.9 failure table and Phase 1 BTstack owner task

**Placeholder scan:** No "TBD", "implement later", "etc". All commands and code blocks are concrete.

**Type consistency:** `StackchanProtocol::Transport` / `Transports::Uart` / `Transports::Ble` / `Transports::BleConnector` used consistently. `BLE::GattDatabase`, `BLE::AdvertisingData`, `BLE::UART` referenced as documented in the picoruby-ble gem; Step 1 of Task 1.11 explicitly notes verifying API spelling against actual mrblib.

**Potential issues to flag at execution time:**
1. `core_bluetooth` gem API surface (Tasks 2.2/2.3) is a best-guess — verify the chosen gem exposes a synchronous-style API or wrap accordingly.
2. mrbgem.rake `build.name` detection (Task 1.5) needs validation against an existing dual-platform gem — Step 2 of that task does that lookup explicitly.
3. CRC16 polynomial/init in the web demo (Task 2.9) — verify against the existing FrameWriter.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-05-15-ble-on-cores3.md`.

Two execution options:

1. **Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration. Good fit because each phase has clear smoke-pass / smoke-fail boundaries that map well to subagent reviews.

2. **Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints. Good fit if you want to babysit each step in real time.

Which approach?
