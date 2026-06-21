# [picoruby-ble] BTstack タスクから mruby VM を操作することによる cross-thread なヒープ破壊

> bist 下書き（esa MCP 未接続のためローカル保存）。人間が picoruby/picoruby の GitHub issue へ転記する想定。
> 丁寧な技術文書として記述しています。

## 概要

`picoruby-ble` の `BLE_write_data`（`mrbgems/picoruby-ble/src/mruby/ble.c`）は、ATT の write コールバック
（`att_write_callback`）から呼び出されますが、このコールバックは **BTstack の run-loop タスク上**で実行されます。
にもかかわらず、当該関数は共有された単一の mruby VM (`_mrb`) に対して `mrb_str_new` / `mrb_hash_*` /
`mrb_ary_*` を直接呼び出しております。

一方で Ruby VM 本体はアプリケーションの別タスク（メインタスク）で動作しています。マルチコア、あるいは
プリエンプティブなポート（例: ESP32 の BTstack ポート。専用 FreeRTOS タスクで run-loop を回し、かつ
デュアルコア SoC）では、この 2 つのタスクが thread-safe でない mruby のアロケータ／GC を**同時に操作**するため、
ヒープのフリーリストが破壊され、後続の何気ない確保処理が不正アドレスへの書き込みで panic します。

`BLE_push_event` も同様に、BTstack タスクから `mrb_malloc` / `mrb_free` を呼び出しており、同じ問題を抱えています。

## 環境（確認済み）

- ターゲット: ESP32-S3 デュアルコア（M5Stack CoreS3）、PSRAM 8MB
- ESP-IDF v5.4.2、BTstack ESP32 ポート（BLE 単独構成）、picoruby（mruby VM）
- ロール: peripheral、Nordic UART Service 相当

## 該当コード

`src/mruby/ble.c`:

```c
int
BLE_write_data(uint16_t att_handle, const uint8_t *data, uint16_t size)
{
  ...
  mrb_value write_value = mrb_str_new(_mrb, (const char *)data, size);   // ← BTstack タスクで mruby 確保
  write_values_mutex = true;
  mrb_value queue = mrb_hash_get(_mrb, write_values, key);               // ← mruby
  if (!mrb_array_p(queue)) {
    queue = mrb_ary_new_capa(_mrb, 4);                                   // ← mruby
    mrb_hash_set(_mrb, write_values, key, queue);                        // ← mruby
  }
  mrb_ary_push(_mrb, queue, write_value);                                // ← mruby
  write_values_mutex = false;
  return 0;
}
```

同期は `src/ble.c` の素の `bool` で行われており、これは atomic でも本物の mutex でもありません。
原作者の方も、その不十分さをコメントで認識されています。

```c
/* Workaround: To avoid deadlock
 * TODO: Maybe we need a critical section instead of these simple mutex */
static bool packet_mutex = false;
static bool write_values_mutex = false;
```

これらの `bool` は、(1) cross-core のメモリバリアを持たず、(2) **メインタスク側の無関係な確保処理や GC を
まったく保護しません**（実際の panic は、アプリ側コードの普通の `Array#push` の最中に発生します）。

## 顕在化の条件

`BLE_write_data` の呼び出し頻度が高い場合にのみ顕在化します。1 つの inbound チャンクごとに 1 回呼ばれ、
ストリーミング時は毎秒数百回に達します。コマンドが数個程度の低頻度な write では踏まないため、データを
ストリーミングする機能（音声、ファイル転送など）が入るまで潜在化します。

## 最小再現（ハードウェア非依存）

LCD やサーボなどに依存せず、`picoruby-ble` の peripheral と「write-without-response のフラッディング」だけで
再現します。共有 BLE の Ruby API しか使わないため、ポート非依存です。

### device 側（peripheral）

```ruby
require 'ble'

class BleRacePeripheral < BLE
  AD_TYPE_FLAGS = 0x01
  AD_TYPE_NAME  = 0x09
  AD_FLAGS      = 0x06
  BTSTACK_EVENT_STATE              = 0x60
  HCI_EVENT_DISCONNECTION_COMPLETE = 0x05

  SVC_UUID = "\x9e\xca\xdc\x24\x0e\xe5\xa9\xe0\x93\xf3\xa3\xb5\x01\x00\x40\x6e"
  RX_UUID  = "\x9e\xca\xdc\x24\x0e\xe5\xa9\xe0\x93\xf3\xa3\xb5\x02\x00\x40\x6e"
  RX_PROPS = BLE::WRITE | BLE::WRITE_WITHOUT_RESPONSE | BLE::DYNAMIC

  def initialize
    @adv = BLE::AdvertisingData.build do |a|
      a.add(AD_TYPE_FLAGS, AD_FLAGS)
      a.add(AD_TYPE_NAME, "BleRaceRepro")
    end
    db = BLE::GattDatabase.new do |d|
      d.add_service(BLE::GATT_PRIMARY_SERVICE_UUID, SVC_UUID) do |s|
        s.add_characteristic(RX_PROPS, RX_UUID, RX_PROPS, "")
      end
    end
    @rx = db.handle_table[SVC_UUID][RX_UUID][:value_handle]
    @rx_bytes = 0
    super(:peripheral, db.profile_data)
  end

  def packet_callback(event_packet)
    case event_packet[0]&.ord
    when BTSTACK_EVENT_STATE
      advertise(@adv) if event_packet[2]&.ord == BLE::HCI_STATE_WORKING
    when HCI_EVENT_DISCONNECTION_COMPLETE
      advertise(@adv)
    end
  end

  def heartbeat_callback
    while (v = pop_write_value(@rx))
      @rx_bytes += v.bytesize
    end
    # メインタスク側のアロケータ／GC を稼働させ、BTstack タスクの確保と競合させる
    3000.times do
      a = []
      20.times { a << ("x" * 16) }
    end
    puts "[repro] rx_bytes=#{@rx_bytes}"
  end
end

sleep_ms 1000
puts "[repro] BleRacePeripheral starting"
BleRacePeripheral.new.start
```

### central 側（フラッディング）

`BleRaceRepro` に接続し、RX キャラクタリスティックへ write-without-response を可能な限り高速に送り続けます。
（nRF Connect の write ループ、別の Pico W、任意の BLE セントラルで代替可能です。）

## 期待結果

- 修正前のビルド: 数秒で `Guru Meditation Error ... (StoreProhibited)` が発生し、backtrace が mruby の
  アロケータを通過します。
- 修正後のビルド: クラッシュせず、`rx_bytes=` が増え続けます。

## 実機で採取した panic dump（確認済み）

同じコードパス（write-without-response で音声クリップをストリーミング）を実行する実アプリケーションで採取し、
`idf_monitor` がシンボルを解決したものです。

```
Guru Meditation Error: Core 0 panic'ed (StoreProhibited). Exception was unhandled.
PC: 0x42042cc2 est_malloc   EXCCAUSE 0x1d (StoreProhibited)   EXCVADDR 0xfdfcfd04
A11 0xfdfcfcfc   (破壊された free-list ポインタ)
Backtrace:
  est_malloc <- est_realloc <- mrb_basic_alloc_func <- mrb_realloc_simple <- mrb_realloc
  <- ary_expand_capa <- mrb_ary_push <- mrb_ary_push_m <- mrb_vm_exec
  <- execute_task_vm (task.c) <- mrb_protect_error <- execute_task (task.c)
  <- task_run_body (task.c) <- mrb_task_run <- picoruby_esp32 (picoruby-esp32.c:116)
  <- app_main (main.c:5) <- main_task <- vPortTaskWrapper
```

クラッシュは普通の `Array#push` → `ary_expand_capa` → `mrb_realloc` で発生しており、アロケータが破壊された
free-list ポインタ（`0xfdfcfcfc`）を経由して書き込んでいます。すなわち BTstack タスクからの並行確保により、
mruby ヒープが事前に破壊されていたことを示します。クリップ長に依存し、約 12 秒（約 96KB）では無事、
約 15 秒では reboot しました。

## 検証状況

- 確認済み: 上記クラッシュは、Ruby VM が稼働している最中に長いクリップを write-without-response で
  ストリーミングすることで、ESP32-S3 上で安定して再現します。
- 未実施: 上記「最小再現」スクリプト単体での実機確認（同一コードパスを再現するものですが、単体での実行確認は
  これからです）。
- RP2040 / Pico W: 該当コードは共有ですが、確実な顕在化はポートの `async_context` の方式に依存すると考えられます
  （プリエンプティブな `threadsafe_background` なら競合し得る／協調的な `poll` なら競合しない）。RP2040 では未確認です。

## 修正方針（提案）

BTstack タスクのコールバックからは mruby VM を一切触らないようにします。`BLE_write_data` / `BLE_push_event`
では、受信バイト列を素の C の FIFO（`malloc`/`free`。ホスト側ヒープは thread-safe）へ本物のロックの下でコピーする
だけにとどめ、mruby の `String` 生成はメインタスク側の `pop_write_value` / `pop_packet`（ロックの外）でのみ行います。
ロックのプリミティブはポート提供とします（ESP32 は FreeRTOS の再帰 mutex、RP2040 は `critical_section_t` 等）。
なお mruby のアロケータ関数だけをロックで囲んでも不十分です。BTstack タスクで誘発された GC が、メインタスク側の
オブジェクト操作と競合し得るためです。
