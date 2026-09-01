# stackchan-picoruby

StackChan を PicoRuby（[R2P2-ESP32](https://github.com/picoruby/R2P2-ESP32)）で動かすための個人プロジェクト。隣ディレクトリ `../StackChan` にある M5Stack 公式ファームウェアは参照のみ、絶対に変更しない。

## esa保存先

このプロジェクトに関連する記事・WIPメモ・進捗記録・spec共有は、すべて以下に保存する。

- esa team: `ksbrb`
- カテゴリ: `ｽﾀｯｸﾁｬﾝ` 配下

`mcp__esa__esa_create_post` を呼ぶときは `team_name=ksbrb`、`category` に上記パスを指定。

## 対象ハードウェア（実機）

- 製品: [M5 StackChan AI デスクトップロボット (Switch Science 11129)](https://www.switch-science.com/products/11129)
- SoC: ESP32-S3 デュアルコア LX7 240MHz / 16MB Flash / 8MB Quad PSRAM
- 通信: WiFi 802.11 b/g/n、Bluetooth 5 LE、赤外線TX/RX
- ディスプレイ: 2.0" IPS LCD 320×240 65536色、静電容量マルチタッチ
- IMU: **BMI270 + BMM150**（加速度・ジャイロはBMI270、磁気はBMM150）
- 環境センサ: LTR-553ALS-WA（近接・環境光）
- カメラ: GC0308 0.3MP (640×480)
- アクチュエータ: フィードバックサーボ2個（首振り360°連続回転、チルト90°）
- LED: 12個 RGB
- 頭タッチ: 3ゾーン（Si12T 系）
- マイク: デュアル / スピーカー1W
- その他: NFCモジュール、microSD、PCF8563 RTC、PY32 IO Expander、550mAhバッテリー、USB-C

公式ファームウェア (`../StackChan/firmware/main/hal/board/`、`../StackChan/firmware/main/hal/drivers/`) のC++実装はピン配置・初期化シーケンスの参照に使う。

## 関連リポジトリ

- 公式ファームウェア（参照のみ）: `../StackChan`
- PicoRuby on ESP32: [picoruby/R2P2-ESP32](https://github.com/picoruby/R2P2-ESP32)
- 参考になる自作 PicoRuby ドライバー（バッシュさん本人作）:
  - `bash0C7/picoruby-mpu6886`（IMU、構造が近い）
  - `bash0C7/picoruby-vl53l0x`
- PC側AI: `bash0C7/rb-foundation-model-mac`（Apple Foundation Model のRubyバインディング）
- PicoRuby本体（仕様確認用）: `picoruby/picoruby`

上の `<org>/<repo>` 表記はこの repo の外にあるクローンを指す。バッシュさんの環境では
`~/dev/src/github.com/<org>/<repo>` に置いてあるが、この repo のビルド・テストはどれにも
依存しない（必要なものは `rake vendor:setup` が取得し、mrbgem は build 時に GitHub から取る）。
読むために clone する時だけ、手元のレイアウトに読み替える。

## アーキテクチャ方針

PC連携アバターパターン：

- **StackChan側**：R2P2-ESP32 + PicoRuby スクリプト。I/O 端末として動作。センサ値を読んでシリアルで送信、PCからのコマンドでサーボ/LED/表情を駆動
- **PC側**：PicoRuby (`pc/stackchan-pico`) の unified CLI `stackchan <verb>` 経由。Mac との通信は BLE NUS (picoruby-ble の darwin port、central 側)。`stackchan <verb>` は launchd 管理の daemon に attach するだけ。起動は `bundle exec rake pc:up` (毎回作り直す決定論的操作)、停止は `rake pc:down`。daemon が永続 BLE link + touch reader を保持。AI 判断 (rb-foundation-model-mac) と macOS TTS は CRuby sidecar (`pc/sidecar`) に隔離し dRuby で橋渡し。WiFi 経路 (picoruby-esp32 + picoruby-socket + picoruby-net-http/-mqtt/-websocket) は sdkconfig 有効 + mbedTLS 完成済み、wiring 未着手。USB-serial は uploader / debug 用途

### 設計の核心

核心機能は **BLE 経由でサーボに絶対位置 (normalized 0..100 + 方向 key) を指定して期待通り動かすこと**。Face / LED / blink animation は装飾の二次扱い。HITL は通常「サーボ正面の物理アライン (個体ごとの raw zero ズレを人間が手で吸収)」を指し、顔の見た目承認とは別。新 design / refactor / question 構成では「サーボ絶対位置制御の精度」を最優先軸にする。

### Firmware vs application boundary

- Firmware (mrbgems, requires `build_flash`): hardware drivers + stable
  protocol framework (`StackchanProtocol::FrameParser` only).
- Application (`app/application.rb`,
  deploy via `upload_appmrb`): all StackChan business logic — `Face` DSL,
  `Dispatcher`, BLE peripheral, cold-boot init.
- The CRuby picotest orchestrator (`test/picotest/harness.rb`) loads/extracts
  application class definitions via prism AST through `lib/ruby_class_extract.rb`.
  Application code must keep class definitions free of `< BLE` patterns at the
  class-body top level so the exclusion filter skips them cleanly.

## CoreS3 cold-boot 初期化シーケンス

**LCD と WS2812 を cold-boot で確実に出すには、ESP32 SoC の SPI/GPIO init だけでは不足。** 必ず system I2C bus (SDA=GPIO 12 / SCL=GPIO 11) で以下を順に叩く:

1. **AXP2101 PMIC @ 0x34** — `0x97 / 0x69 / 0x30 / 0x90 / 0x94 / 0x95 / 0x27 / 0x99` を全部書く。`0x90 = 0xBF` (LDO 一括 ON) だけでは LCD バックライトと一部 rail が立たない。Reg 0x99 が DLDO1 voltage = LCD/backlight rail
2. **AW9523 IO Expander @ 0x58** —
   - `Reg 0x02 (P0 output) = 0b00000111` で **WS2812 用 5V rail を enable**。これを書かないと PY32/WS2812 chip 側を完璧に叩いても暗黒のまま
   - `Reg 0x03 (P1) 0x81 → 20ms → 0x83` で P1.1 を pulse、これが LCD reset
   - 書き順は reference (`../StackChan/firmware/main/hal/board/stackchan.cc:148-156`): P0 output → P1 output → CONFIG_P0 → CONFIG_P1 → GCR → LEDMODE_P0 → LEDMODE_P1
3. **PY32 IO Expander** — GPIO 0 (VM_EN) HIGH + 200ms settle、GPIO 13 (WS2812 data line) を push-pull 出力で初期化、`refresh_leds` は read-modify-write 必須 (count を wipe しない)
4. **ILI9342 driver の `rst_pin` / `bl_pin`** — AW9523 / AXP2101 経由なのでダミー GPIO (例 GPIO 1 等の未配線) を渡す
5. **BLE を続けるなら cold-boot 完了後に `sleep_ms 3000` で必ず yield する**。cold-boot 全体 (特に Face::Neutral.draw の 150KB pixel push) は同期 SPI/I2C で CPU を占有し、BTstack の FreeRTOS task が初期化を完走できない。yield せず `BLE.new` → `start` に入ると `gap_advertisements_enable(1)` は呼ばれても **RF emit が silent fail** する (device-side log には `HCI WORKING — advertising` が出る、Mac scan / iPhone nRF Connect では一切見えない)。3000ms は安全策

実装は `app/application.rb` (cold-boot 後 sleep_ms 3000 入り) を参照。`app/app.rb` は upload race-free 用の 10 秒 heartbeat → exit パターン。

**PY32 init region の `puts` は削除禁止**: `application.rb` の PY32IOExpander / StackchanLed init 区間 (L412 周辺) の 5 個の `puts` は debug 出力に見えるが必須。削るたび crash 位置が前へズレ、最終的に PY32IOExpander init で LoadProhibited する PicoRuby bytecode-layout-dependent な memory bug。`# REQUIRED FOR PY32 COLD-BOOT` マーカーコメントを付けて keep。

## PicoRubyの制約・互換性の調べ方

固定リストに頼らない。以下の順で確認する。

確認済みの差異 (2026-08-31 に host / darwin 両 VM で実測): **`rescue` 節の裸の `raise` は元例外を
再送出しない** — 空メッセージの `RuntimeError` が新たに上がり、クラスもメッセージも失われる (CRuby は保存)。
再送出は必ず `rescue Foo => e` … `raise e` と書く。再現: `begin; raise "x"; rescue => e; raise; end` を
両 VM で走らせてメッセージを見る。

実機でしか出ない制約が 2 つある。どちらもホストでは再現しないので、host test が緑でも残る。

- **device の Ruby から C 経由でブロックを yield する構文を描画・BLE の深い経路で使わない**。
  mruby VM を回す FreeRTOS タスクのスタックは 8 KB (`PICORB_TASK_STACK_SIZE`、
  `components/picoruby-esp32/picoruby-esp32.c`)。`mrb_vm_exec` の Xtensa プロローグは
  `entry a1, 0xb50` = 2896 バイトで、1 段ネストするだけで約 3.1 KB 積む。`Array.new(n) { ... }`
  や `String#dup` は C から `mrb_yield` を呼ぶのでこれに該当する。同じことは `while` ループと
  C 実装メソッド (`String#*`、`Array#<<`) で書けばネストしない。症状は
  `stack overflow in task picoruby_task` のブートループで、advertising の約 5 秒後 (初回 blink)
  に出る。フレーム幅は `xtensa-esp32s3-elf-objdump -d <elf> --disassemble=<関数>` の `entry` で測れる
- **`String#[]=` は差し込む先の文字列全長に比例する**、slice の大きさではない
  (`str_replace_partial`、mruby の `src/string.c`)。20 KB のバッファに 1 行ずつ差し込むと
  PSRAM 速度で 1 回あたり約 2.5 ms かかる。行ごとに別の String を持てば避けられる。
  ホストではバッファが L1 に収まるため完全に見えない

1. `chiebukuro-mcp` の Ruby/PicoRuby ナレッジDB (`chiebukuro_query_ruby_knowledge` / `chiebukuro_semantic_search_ruby_knowledge`)
2. 答えが無い・根拠が必要なら picoruby 本体 (`vendor/R2P2-ESP32/components/picoruby-esp32/picoruby`、または `picoruby/picoruby` のクローン) を Explore subagent で調査
3. 仕様確認できないまま「禁止メソッド」前提で書かない

## BLE servo control protocol

Servo positions are normalized to direction-key + magnitude (NOT raw values):

- **yaw**: `<YL:0..100>` (StackChan's left) or `<YR:0..100>` (right), mutually exclusive (YL wins on conflict)
- **pitch**: `<PU:0..100>` (up only — down is not protocol-reachable; if needed, use `<torque:off>` and move by hand)
- **timing**: `<T:ms>` (duration) or `<V:speed>` (velocity), at most one
- **torque (rare)**: `<torque:on>` / `<torque:off>` (full word key — frequency rare, readability priority)
- **selftest (rare)**: `<selftest:run>` (yaw ±10 raw nudge — UART round-trip alive check)
- **read_pos (rare)**: `<read:pos>` (full-word key) — returns `<yaw_raw:N,pitch_raw:M>` detail (or `unknown` parts). Used only by `stackchan-ble-control calibrate`; no other operational caller.

Cold-boot starts torque OFF + `Face::Closed` (idle indicator). Operator physically aligns
head to forward, then sends `<torque:on>` to engage. Detail frame on position commands
reports `<YL_actual:N,PU_actual:N>` or `<YL_actual:unknown,PU_actual:unknown>` (where
unknown is a protocol-level signal that operator manual calibration is needed).

**detail は「コマンド受信時点の姿勢」であり、移動完了後の姿勢ではない。** device は
`@head.apply` (移動指令) の直後に読むので、`<T:600>` 付きコマンドの detail には移動前の値が出る
(`YL:30` の直後に `YL_actual:1`、次コマンドの detail に前回の 29 が出る、の形)。移動完了後の値を
ACK に載せると ACK が T ms 遅れ、その間 LinkLoop が止まって Phase 1 で解体した遅延要因が戻るため、
この意味付けを採る (2026-08-31 裁定)。detail の運用目的は `unknown` 検出 = キャリブレーション要否の
判定で、これは読み取り時点に依存しない。移動後の姿勢が要るときは移動完了を待って `<read:pos>` を撃つ。

CLI (実行は `pc/stackchan-pico/bin/stackchan <verb>`):
`stackchan servo --yaw-left 50 --pitch-up 30 --time 500`、`stackchan torque on`、`stackchan selftest`。
servo の Exit code 6 = `EXIT_CALIBRATION_NEEDED`。

Calibration: `stackchan calibrate --align-only` (daily startup: torque off → operator aligns forward → torque on).
Anchor recal: `stackchan calibrate [--samples N] [--format ruby|json|env]` (5-pose, prints SERVO_*_ZERO / RANGE_RAW constants for paste into application.rb). Exit code 6 = device read unknown, 7 = verify fail / abort. Spec: `docs/superpowers/specs/2026-05-21-manual-calibration-cli-design.md`.

### BLE 実装 notes

- **picoruby-ble の `heartbeat_callback` tick は ~1 秒** (NOT 100ms)。NOTIFY 周期や idle-detection timeout を heartbeat 数で計算する時は「tick=1s」前提に
- **Mac CoreBluetooth idle-disconnect window は経験値 15-20 秒**。無 PDU 状態が続くと link 切断、保持には 10 秒以下の notify or write を流す
- **advertise しているはずのロボットが Mac 側 scan で見えない時、まず `sudo pkill bluetoothd` を疑う**。macOS の `bluetoothd` は CoreBluetooth の scan 結果・device name を stale にキャッシュする well-known 問題があり、System Settings 上の Bluetooth off/on トグルでは直らない(プロセス自体は再起動されないため)。ロボット側コードや BLE role ロジックを疑って延々 A/B するより先に、変更していない別の BLE central (例 `PicoRubyBLE.app`) で同じ症状が起きるか確認し、環境側要因を切り分ける(2026-08-20 発生、`sudo pkill bluetoothd` 後に解消を確認)
- **Mac BLE scan/connect/write は `rb-corebluetooth-mac` 経由で Bash から claude 自身が叩ける**。advertise 検出や smoke を「人間に iPhone nRF Connect 開いて」と頼まず、`stackchan-ble-control` CLI で autonomous に実行する
- **BLE 検証中は serial monitor を並走させない**。`bin/capture-with-pty ... rake r2p2:monitor` (idf_monitor) は port open 時に DTR/RTS で CoreS3 を reset するため、BLE connect/write/ACK の最中に走らせると device が cold-boot をやり直し advertising が消え、`no device with name prefix` や ACK timeout の偽陽性が出る。BLE smoke / servo / face は **monitor 無しで `stackchan-ble-control` CLI 単独**で実行する。device 側ログがどうしても要るなら reset を覚悟して 1 回キャプチャ→その boot で完結する検証だけにする
- **`rb-corebluetooth-mac` の native 拡張は使用前にビルド必須**。`cd ../rb-corebluetooth-mac && bundle install && bundle exec rake compile` で Swift dylib + Ruby `.bundle` を生成。未ビルドだと CLI が `Library not loaded: @rpath/libCoreBluetoothMac.dylib` で落ちる。Ruby ABI 切替時は再 compile 必要
- **BLEのevent drainは「`pop`がeventを返したかに関わらず、毎tick必ず`_event_popped`を呼ぶ」で書く**。ESP32 portではNimBLEのwrq/evqが`_event_popped`の中でしかRubyに上がらず、darwin portもSwift FIFOを`_event_popped`で1 packetずつ移すため、`pop`がeventを返した時だけ`_event_popped`を呼ぶ形（gemの`BLE#start`の形）では1 s heartbeatまで何も届かない。実装はdevice側が`StackChanApp#run`（`StackchanApp::LinkLoop#tick`: `@event_queue.pop(timeout_ms: 20)`→無条件`_event_popped`、`app/application.rb`）、PC側が`StackchanRadio#pop_and_dispatch`（無条件`_event_popped`→`@event_queue.pop(timeout_ms: 0)`、`pc/stackchan-pico/app/ble_client.rb`）。`BLE#start`のoverrideは書かない（`@event_queue.pop`を呼ばないoverrideはevq drainが止まり`advertise()`すら効かなくなる）。`pop_packet` / `pop_heartbeat` / `BLE::POLLING_UNIT_MS`は存在しないAPI。
- **macOS 側 CoreBluetooth は TCC 経由でしか許可されない**。`build/host/bin/picoruby` の直接 fork/exec は署名済み・許可済みでも TCC `SIGABRT` で落ちるので、シェルから起動するなら `open -a` で `~/Applications/StackchanPico.app` (`rake pc:app_bundle` が生成、`NSBluetoothAlwaysUsageDescription` 入り Info.plist) を叩くしかない。`rake pc:vm_build` の度に `rake pc:app_bundle` を再実行 (ad-hoc 署名がバイナリの exact bytes に紐づくため)。ただしこれは**シェルからの fork/exec の話**で、launchd 経由には当てはまらない (2026-08-31 spike で確認: LaunchAgent の `ProgramArguments` に bundle 内バイナリを直接指定して `launchctl bootstrap` すると CoreBluetooth が動く。launchd が責任プロセスになると bundle ID の Bluetooth 許可がそのまま効く)。`rake pc:up` はこの経路を使い、LaunchAgent の `ProgramArguments` に bundle 内バイナリを直接指定する。
- **レイテンシ計測**: `tools/latency_baseline.zsh`（wrapper込みwall clock、`LOG=`で出力先）→ `ruby tools/latency_summary.rb <log>`でverbごとの中央値 / p90 / failures。device側は1コマンドごとに`[t] rx=<us> ack=<us> d=<us>`（serial）、Mac側はdaemon.logに`[t] <frame> ack=<ms>ms[ detail=<ms>ms]`（timeout時は`ack=timeout` / `detail=timeout`）。現状値と内訳はvault `02_dev_docs/stackchan-picoruby/review/2026-08-30-latency-investigation.md` §6。face別の内訳は`ROUNDS=8 tools/face_profile.zsh`（labelにface名を残すので`latency_summary.rb`がface単位で集計する）。**セッションを跨いだ数値を比較しない** — 同じコードでもセッション間で 15〜25% ぶれる。速くなった/遅くなったの判定は必ず同一セッション内で取り直した 2 点で行う。
- **LCD描画のコストを`SPI#write`の回数で説明しない**。呼び出しを428回から10回に落としても所要時間は7〜9%しか動かない(実測)。支配項はPicoRubyがBresenham/楕円のループを解釈実行する時間で、表情ごとの差もprimitive数に比例する。面積でもバイト数でもない。詳細と残る高速化余地はREADMEの「Latency and remaining headroom」
- **描画コストの計測にdevice側の`puts`を使わない**。`ruby tools/face_spi_cost.rb`が実ドライバをカウンタ付きSPIで空回しし、face別の`SPI#write`回数・RAMWR数・バイト数をホストだけで出す(latency予測は当たらないので回数の比較にだけ使う)。device側に一時ログを足すとboot loopに入り、USB抜き差しでしか復旧できない

### BLE audio half-duplex protocol

btstack FreeRTOS thread と PicoRuby main_task が同時に mruby heap に触れると crash するため、受信フェーズと再生フェーズを完全分離した半二重設計を採用する。

**受信フェーズ（device 側 AudioReceiver#consume）**:
1. `<A:N>\n` frame を受信 → PC に `<A:ready>\n` を notify
2. `T = (N * 1000 / 8000) + 3000 ms` だけ `Machine.delay_ms` で静止（main_task が heap に触れない）
3. T 経過後に BLE RX queue を全 drain してバッファを確保
4. mu-law bytes を I2S に書き込んで再生

**送信フェーズ（PC 側 Streamer#stream_halfduplex）**:
1. `<A:N>\n` を write_without_ack で送信
2. `READY_WAIT_S = 1.5s` sleep（device の heartbeat tick が `<A:N>` を拾うのを待つ）
3. MTU 単位でバイト列を blast
4. `N/8000.0 + 2.0s` sleep（device が再生を完走するのを待つ）

**T の根拠**: 6KB/s BLE dip でも blast 完了後に 1500ms マージンが残る。標準音声 ≤3000 bytes なら T ≈ 3375ms、転送は 0.5s 以内。

Non-audio frames（`<F:N>`、`<YL:N>` 等）は AudioReceiver をバイパスして Dispatcher へ直行する。

Spec: `docs/superpowers/specs/2026-05-21-cold-boot-torque-off-and-normalized-protocol-design.md`

## 開発ルール

- ドライバー開発は基本 https://picoruby.org/terminal で実装・実機検証
- C拡張のmrbgemsが必要な場合のみ R2P2-ESP32 のビルドツリーに組み込む
- PicoRubyドライバーの構成は picoruby-mpu6886 / picoruby-vl53l0x のレイアウトを踏襲
- 公式 `../StackChan` には書き込まない。ピン配置や初期化シーケンスは読み取って参考にするだけ
- spec / plan は `docs/superpowers/specs/` `docs/superpowers/plans/` に置く

### PicoRuby-native test suite (picotest)

Device-side logic tests run on a host `picoruby` VM via **picotest** (`picoruby/picoruby` の `picoruby-picotest`), not CRuby test-unit. Two-process model: a CRuby orchestrator extracts `app/application.rb` のクラス本体を取り出し、picoruby VM 上で assertion を実行する。

- 実行: `bundle exec rake test` (= `picotest:run`) で 3 suite (device = `test/device`、pc = `test/pc`、shared = `mrbgems/picoruby-stackchan-shared/test`) を同じ host VM で回す。`SUITE=device|pc|shared` で 1 suite、`FILTER=<ファイル名部分文字列>` で絞る (例 `SUITE=pc FILTER=stackchan_central`)。host VM の binary が無ければ `picotest:ensure_vm` が初回だけ自動 build する (`MRUBY_CONFIG=picoruby-test` で `<picoruby tree>/build/host/bin/picoruby` を生成)。
- pc suite は `pc/stackchan-pico/app/ble_client.rb` を prism で抽出し、`test/pc/stubs.rb` の `BLE` stub (`_event_popped` が pending packet を 1 件 queue へ移す darwin port の形) と `test/pc/fake_radio.rb` (`StackchanCentral` から見た radio、notification を N poll 後に配達) の上で回す。`StackchanCentral` は `radio: / sleep_fn: / clock_fn: / log_fn:` を注入できる。`PICOTEST_VM=<picoruby path>` で suite を別の VM (例 `vendor/R2P2-darwin/build/host/bin/picoruby`) で回せる。
- picoruby 更新後に host VM を強制再 build: `bundle exec rake picotest:build`。picoruby tree (`PICORUBY_ROOT`) が無ければ案内付きで abort する (自動 clone はしない)。`r2p2:setup` / `build_flash` / `full_rebuild`はこのhost VM binaryをpicotest無しのconfigで上書きするので、firmwareを焼いた直後の`rake test`も先に`picotest:build`を実行する（症状は`uninitialized constant Picotest`）。
- device test は `test/device/*_test.rb`、pc test は `test/pc/*_test.rb` に `Picotest::Test` サブクラスとして置く。device suite は fakes (`test/fake_*.rb`)、stub prelude (`test/picotest/stubs.rb`: `Machine` カウンタ + `ILI9342::Color`)、抽出した application クラス、scservo gem source を harness (`test/picotest/harness.rb` の `SUITES` テーブル) の `load_files` でこの順に VM へ注入してから各 test を load する。
- `app/application.rb` は **monolithic のまま read-only 入力**。`RubyClassExtract.extract_to_file` (prism) が class/module 本体だけを切り出す (`class ... < BLE` と top-level cold-boot コードは除外)。split しない・コードを動かさない。
- CRuby-only tool のテスト (extractor、`tools/latency_summary.rb`) は `bundle exec rake test:host` (`test-host/*_test.rb` を全部実行)。
- picotest は test クラスごとに OS subprocess を spawn するので cross-file 隔離を構造的に保証する (撤去した Ruby::Box `test_isolated` harness の上位互換)。
- Face geometry golden は canonical draw-call dump 文字列 (`spec/golden/face_<name>.dump`、SHA なし — PicoRuby に digest gem が無いため)。登録は `bundle exec rake face:register_golden FACE=<name>` または `face:register_all_goldens`。
- `pc/stackchan`と`pc/sidecar`（CRuby）は各々の`rake test`。`pc/stackchan-pico/app`のBLE client（`StackchanRadio` / `StackchanCentral`）はpc suite（`SUITE=pc bundle exec rake test`）で回す。

Spec/plan: `docs/superpowers/specs/2026-06-17-picotest-native-test-migration-design.md`, `docs/superpowers/plans/2026-06-17-picotest-native-test-migration.md`。

### mrbgem pitfall (実機で詰まりがち)

- **on-device の `require` 名は gem 名から `picoruby-` を strip した hyphen 形**。`picoruby-stackchan-protocol` → `require 'stackchan-protocol'` (underscore で書くと `LoadError`)。host テスト (CRuby + Bundler) は `$LOAD_PATH` で underscore でも解決するから on-device だけが prebuilt list (`mrbgems/picogem_init.c`) に依存
- **`mrblib/*.rb` 内で sibling ファイルへの `require` を書くと device で fail**。host は test_helper.rb で `$LOAD_PATH` に mrblib を unshift してるから通るが、device の PicoRuby は mrblib path を `$LOAD_PATH` に乗せん。gem build が `mrblib/**/*.rb` を全部 gem bytecode に自動 bundle するので、sibling require は不要かつ有害。`require 'gemname/foo'` は **cross-gem** にのみ使う (`require 'mbedtls'`, `require 'ble'` 等)
- **`build_config/xtensa-esp-picoruby.rb` に新 gem 行追加 → `rake r2p2:setup` 必須**。`rake r2p2:build_flash` 単独では `gem_init.c` / `picogem_init.c` が再生成されず新 gem が含まれない
- **既存 gem の `mrblib/*.rb` 内容を変えただけなら軽量修復ルート**: `cd $R2P2/components/picoruby-esp32/picoruby && MRUBY_CONFIG=$R2P2/components/picoruby-esp32/build_config/xtensa-esp-picoruby.rb rake` → `idf.py build flash`。重い `r2p2:setup` フル不要
- **`conf.gem` 表記は `gemdir:` のみ**。`path:` は picoruby の `MRuby::LoadGems` に拒否される
- **`conf.gem github:` で取る gem は `build/repos/` にキャッシュされ、pull されない**。gem 側を直して push しても、firmware を焼き直すだけでは**入らない**。`clean_picoruby_build` が消すのは `build/esp32-picoruby` の方だけで、clone した実体は `components/picoruby-esp32/picoruby/build/repos/esp32-picoruby/<gem>` に残り続ける。症状は「直したのに測定値が 1 mm も動かない」で、エラーは一切出ない。**gem を直したら必ず `git -C <その path> log --oneline -1` で push した commit か確認し、違えばそのディレクトリを `rm -rf` してから build する**
- **picoruby-uart on-device API の 3 つの罠**: (1) unit symbol は `:ESP32_UART0` / `:ESP32_UART1` / `:ESP32_UART2` (`:UART1` 等を渡すと silent Guru Meditation crash)、(2) `write` 引数は **String only**、Array は TypeError なので `array.pack('C*')` で変換、(3) `read(n)` は timeout_ms 無視 — `readpartial(n)` を使って poll を自前で回す

### bring-up app の書き方 (upload race-free)

- **bring-up app.rb は `loop` を持たず、固定時間 sleep + exit にする**。dispatcher loop が STDIN を独占すると uploader の STX が face byte として消費され、PicoModem session が立たず upload 詰まる
- `app/app.rb` は 10 秒 heartbeat 後に exit して shell に戻る形で、上書き upload がスムーズに通る
- production 用の dispatcher loop を入れる場合は **「特定 frame (例 `E\n`) で exit」または「STX 検出で shell に hand-off」の exit hatch を frame protocol に組み込む** ことを前提にする

### rake は subagent foreground で、可能なら chain task 1 個

- **本プロジェクトの rake task は全て subagent (general-purpose, model: haiku) 経由で foreground 起動**。screen `-dmS` longrun pattern は build / flash / upload / test いずれも使わない (`~/dev/src/CLAUDE.md` の 2 分超ロングバッチ規約に対する **本プロジェクト局所の override**)
- **直列に走る複数 rake task は 1 invocation の chain task にまとめる**。`rake xxx yyy zzz` で順次実行可能。`r2p2:full_rebuild` (`build_flash → wipe → upload → reset`) のように Rakefile 側で chain task として定義し、USB renum 待ちの sleep / monitor guard も task 内で決定論的に持たせる。これが 4 subagent dispatch より一貫性高い
- subagent には rake を **1 chain task foreground 実行するだけ** 投げる。background process / 長 sleep / 複合 wait は main の Bash で組み立てる (例「capture しながら reset」は ① main で `bin/capture-with-pty ... &` ② subagent で `rake r2p2:reset` ③ main で 通知待ち ④ main で log read)
- 結果要約 + pass/fail 報告は haiku に任せ、失敗の深掘り・design 判断は main (opus) が memory + spec から組む
- 例外は `r2p2:setup` (host mruby 一から組む 10〜20 分): 通常 subagent (haiku) で大きい timeout (1200000ms+) で foreground 実行
- **serial port を触る全 rake task は冒頭で `ensure_no_concurrent_monitor` を呼ぶ**。人間が `rake r2p2:monitor` を開いてると CDC byte 競合で uploader/flasher が silent fail するため事前 abort

### serial capture は `bin/capture-with-pty` 必須、生 `cat /dev/cu.usbmodem*` 禁止

reset で USB CDC が再列挙すると raw `cat` は中断する。2 回の boot 失敗で初めて気付くより、最初から `bin/capture-with-pty` (expect で PTY 経由 idf.py monitor) を使う:

```bash
bin/capture-with-pty 30 /tmp/stackchan-picoruby-debug/boot.log \
  bundle exec rake r2p2:monitor
```

`r2p2:monitor` 内部の idf_monitor が renum gracefully に handle するので、reset を別 turn で投下しても取りこぼさない。`stackchan-device-capture-boot` skill が同パターンを encode 済み。

### debug log は `/tmp/stackchan-picoruby-debug/` 配下に集約

skill (atomic) は subagent dispatch 時に `tee /tmp/stackchan-picoruby-debug/<skill-name>.log` を必ず仕込む。grep / cross-reference / 失敗後再現に必要。/tmp 配下なので OS が清掃する、commit 不要

### Coordination は sleep でなく log-watch

subagent dispatch chain や device flash → boot → smoke のような multi-step timing-dependent flow で `sleep N` をハードコードしない。待ち過ぎ = 時間損失、待ち不足 = 次段失敗 → retry → 累積遅延。

- 正解: serial log (`bin/capture-with-pty` or `cat` バックグラウンド + tail/grep) を watch → 「`main_task: Returned from app_main()`」「`$> ` shell prompt」「`HCI WORKING — advertising`」等の既知マーカーを grep 検出 → そこで次段に進む
- subagent 間は log file / sentinel file 経由で「次行ってよし」シグナルを共有
- reset / handshake / 接続初期化のような low-level プロトコルは「過去動いてた」と放置せず、ESP-IDF docs / esptool reset 実装 / idf_monitor / picoruby 本家の USB-CDC handling を定期的に照らして妥当性再検証する (DTR/RTS 操作順序・タイミング・close 時挙動が CDC state machine から逸脱してないか)

### boot 失敗の診断は full log を取ってから仮説立てる

2 行だけ見て「BLE NameError っぽい」と飛びつくと、実際は 1 行目 `(unknown):0: cannot load such file -- xxx (LoadError)` が真因で BLE は二次症状、というケースで時間を溶かす。boot log は必ず:

1. `bin/capture-with-pty` で **cold-boot 全体** を取る (truncate されてないこと wc で確認)
2. `grep -nE "LoadError|cannot load|NameError|Guru Meditation|Returned from app_main" <log>` で **最初の異常から順に** 読む
3. 二次症状 (派生 error) は無視、root cause だけ追う

### Device deploy: skills only, no ad-hoc rake

All device interactions go through `stackchan-device-*` skills (slash
commands available for the human-facing subset). Do NOT invoke `rake
r2p2:*` directly from main context — use the skill so output stays
bounded and the chain composition is auditable.

The `.rb` direct-upload path is forbidden. Always go through `upload_mrb`
(generic) or `upload_appmrb` (autostart); on-device PicoRuby cannot
compile application.rb-scale scripts (codegen stack overflow). Host
picorbc compilation is mandatory.

Iteration cycle:

| Step | Skill |
|---|---|
| edit + host test | `bundle exec rake test` (picotest, host VM) |
| device iterate | `/stackchan-device-iterate` |
| HITL face check | `/stackchan-device-face-verify FACE=...` |

Recovery escalation (escalate after 2 tries):

1. `/stackchan-device-cold-recovery`
2. `/stackchan-device-full-rebuild`
3. Human-driven recovery (USB replug, monitor manual, download mode)

## R2P2-ESP32 ビルド・flash フロー（CoreS3 ターゲット）

stackchan-picoruby 直下の `Rakefile` に `r2p2:*` タスク群を集約。`vendor/R2P2-ESP32`（`rake vendor:r2p2_esp32:setup` で取得、branch `stackchan-integration`）への呼び出しと esp-idf env source を全部ラップ済み。

| タスク | 用途 |
|---|---|
| `rake r2p2:build_flash` | **基本フロー**。`picoruby:build → flash` を 1 screen 内で連結。build 失敗時は rake が flash を自動 skip。build と flash を別 kick する流れは禁止 |
| `rake r2p2:setup` | 初回・target 切り替え後。`setup_esp32s3` = deep_clean + mruby host rebuild + `idf.py set-target esp32s3`。`idf.py fullclean` のみだと target が default `esp32` に戻り IRAM overflow でリンク失敗する |
| `rake r2p2:reset` | RTS pulse で CoreS3 再起動。serial キャプチャ前に呼ぶ |
| `rake r2p2:build_flash_appmrb SRC=app/application.rb` | **picomodem 不要 deploy**。SRC を `R2P2-ESP32/storage/home/app.mrb` に picorbc compile → build → flash で firmware と storage を 1 pass 焼き。firmware をどのみち焼き直す時に使う。詳細は下記「Storage 区画」節 |
| `rake r2p2:flash` / `rake r2p2:build` | 個別 fallback。普段使わない |

### firmware を build する時は必ず clean build

`r2p2:build` / `build_flash` / `build_flash_appmrb` は `clean_picoruby_build` に依存し、picoruby 側の build 出力 (`components/picoruby-esp32/picoruby/build/esp32-picoruby`) を丸ごと捨ててから走る。**この依存を外したり、incremental build で済ませようとしてはいけない。**

`libmruby.a` だけを消す方式では足りない。rake は object リストからアーカイブを組み直すので、**ソースが移動・改名・削除されて中身の意味が変わった `.o` がそのまま新しいアーカイブに入る**。症状は「設定不良に見える undefined symbol」で、原因追及が config 側へ逸れる。

undefined symbol が出たら、まずそのシンボルを **ソースツリーに対して** grep すること。ツリーに無ければ原因は object の陳腐化で、config ではない。`.o` と `.c` の mtime を比べれば一発で分かる。

firmware を焼き直さない app のみの iteration (`r2p2:upload_appmrb` 経由) はこの規律の対象外。そちらは firmware を build しないので陳腐化のしようがない。

### CoreS3 固有の sdkconfig

- `bash0C7/R2P2-ESP32/sdkconfigs/cores3`：`SPIRAM=y` + `SPIRAM_MODE_QUAD=y` + `SPIRAM_SPEED_80M=y`。CoreS3 は **Quad PSRAM 8MB**（Octal でない）。デフォルトの `sdkconfigs/spiram` は `MODE_OCT=y` なので CoreS3 で使うと PSRAM ID 読み失敗 → boot loop
- `bash0C7/R2P2-ESP32/sdkconfig.defaults`：`CONFIG_ESPTOOLPY_FLASHSIZE_16MB=y`（CoreS3 は 16MB Flash）
- SDKCONFIG_DEFAULTS の組み立て：`sdkconfig.defaults;sdkconfigs/usb_console;sdkconfigs/cores3;sdkconfigs/bt_nimble`（Rakefile にハードコード済み）

### sdkconfig fragment 編集後は自動再生成

`idf.py build` は **既に存在する sdkconfig に SDKCONFIG_DEFAULTS を再適用しない**。fragment を編集しても次回 build に反映されないので silent regression に詰む。

対策: stackchan-picoruby `Rakefile` の `r2p2:build` / `r2p2:build_flash` は **`ensure_sdkconfig_fresh`** を先に走らせて、いずれかの fragment が `sdkconfig` より新しい場合は `sdkconfig` を rm → 次の idf.py build で再生成される。手動で `rm sdkconfig` する必要は無い。

### BLE on CoreS3: COEX 完全 disable 必須

BLE-only build (WiFi 並走無し) で `CONFIG_SW_COEXIST_ENABLE=y` のままだと、BT controller の内部 task `btdm_controller_on_reset` → `bt_rf_coex_hook_st_set` → `coex_schm_status_bit_clear` → **ROM `coex_schm_lock`** で **uninitialized semaphore handle (`0x82xxxxxx` 等の高 bit set) を semphr_take して LoadProhibited panic**。

ROM 側の `coex_schm_env` 参照経路が IDF v5.4 + ESP32-S3 + BLE-only で破綻している (詳細は addr2line + 一行 disasm で確認済)。`sdkconfigs/bt_nimble` で **全 coex 関連 flag を `n`** に：

```
CONFIG_SW_COEXIST_ENABLE=n
CONFIG_ESP_COEX_SW_COEXIST_ENABLE=n
CONFIG_ESP_COEX_ENABLED=n
```

これで `bt.c` 内 `coex_schm_status_bit_clear_wrapper` 等が `#if CONFIG_SW_COEXIST_ENABLE` ガードで no-op になり、BT controller の coex hook も harmless 化、ROM 経路に到達しない。WiFi 起動時に coex 必要になったら戻す (この時は `coex_schm_init` が正しく走るか別 issue として再評価)。

### BLE backend は NimBLE (upstream: picoruby/picoruby PR #427)

`R2P2-ESP32` の BLE backend は NimBLE (`picoruby-ble/ports/esp32/nimble_owner.c`)。この ESP32 porting は https://github.com/picoruby/picoruby/pull/427 として upstream 化中で、目標は ESP32 porting の実装充足。実機動作は stackchan-picoruby で主要パスは確認済み（カバレッジ不明）。

`nimble_owner.c` の `host_task` が `nimble_port_run()` を専用 FreeRTOS task として実行し、GATT access callback は "NimBLE host task only" とコメントされている。公開 API (`nimble_owner.h`) は `picoruby_nimble_start/stop/started/own_addr_type/enqueue_event/heartbeat_enable` の 6 個のみで、cross-thread dispatch (Ruby thread からの呼び出しを NimBLE host thread に同期させる) API は無い。Ruby thread から NimBLE API を直接呼ぶ経路 (`ble.c` / `ble_central.c` / `ble_peripheral.c`) があれば無保護になるため、変更時はそこを直接確認する。

cross-thread mruby heap 破壊対策自体は backend 非依存で必要（`picoruby-ble-bridge` gem、`mrbgems/picoruby-ble-bridge/README.md` 参照）。

#### picoruby-ble を別 lineage から sync する時の手順

「PR#427（origin/master rebase 済み）で検証済みの picoruby-ble を実機で回帰確認しよう」に類する依頼は、**見つかっている個別バグの cherry-pick ではなく gem 本体の lineage 乗り換えを意味する**。個別バグだけ移植すると upstream 側で積み上がった他の fix（GC root leak、role 切替時の profile leak 等）が回帰確認から漏れる。手順:

1. コピー対象は `mrblib/` `src/` `include/` `sig/` `mrbgem.rake` と、CMakeLists.txt が個別列挙する `ports/esp32/{ble.c,ble_central.c,ble_peripheral.c,nimble_owner.c}` + 対応 `.h` のみ。`example/` `probe/` `old_test/` `ports/esp32/test/` は compile 対象外なので触らない
2. コピー後、**必ず実機ビルドまで通して mruby-task の C API が揃っているか確認する**。picoruby-ble の ESP32 port は `mrb_task_queue_push` / `MRB_TASK_QUEUE_PUSH_OK`（`mrbgems/picoruby-mruby/lib/mruby/mrbgems/mruby-task/include/task.h`）に依存する。この header は picoruby 本体にネストした **`mruby/mruby`（upstream、bash0C7 管理外）submodule** 由来で、pin が古いと `implicit declaration of function` で build が落ちる。origin が upstream なので新規 commit は書かず、目的の sha が既にローカル履歴にあるか `git cat-file -e <sha>` で確認して `git checkout <sha>` する（新しい lineage 側の同submoduleが指す sha を `git log -1` で調べれば分かる）
3. `pop_packet` / `pop_heartbeat` / `BLE::POLLING_UNIT_MS` を直呼びする全ファイル（`grep -rn "pop_packet\|pop_heartbeat\|POLLING_UNIT_MS\|_event_popped\|_event_queue_cleared\|@event_queue\|hci_power_control"`。`app/application.rb` と `pc/stackchan-pico/app/ble_client.rb` が主な該当）を上の Task::Queue パターンに migrate する。app側が直接使うgemのprivate API（`_event_popped` / `_event_queue_cleared` / `@event_queue` / `hci_power_control`。`app/application.rb`の`StackChanApp`と`pc/stackchan-pico/app/ble_client.rb`の`StackchanRadio`）は新lineageで名前・可視性が変わっていないかを同じgrepで確認する。
4. **compile 成功は検証完了の証拠にならない**。migrate 漏れは実行時 `NoMethodError` や advertising 不通としてしか出ない。`rake r2p2:ble_control_smoke` / `ble_servo_smoke` / `ble_torque_smoke` まで実機で通して確認する

**位置付け**: host 層 (GATT discovery / advertise behavior / CCCD subscribe semantics 等) の正しさは Bluetooth Core Spec と NimBLE 自身の docs を参照する。ESP-IDF docs は controller / PHY / coex 層のみの参考に使う。host 側の bug (GC safety, binding) は picoruby-ble fork (upstream PR #427) で直す。

### Storage 区画は `idf.py flash` で wipe される

`idf.py flash` は build/storage.bin も含めて 4 partition 全部書き込む → **`/home/app.rb` は build_flash 毎に消える**。flash 後は必ず `rake r2p2:upload SRC=...` で再 upload してから `rake r2p2:reset`。

#### app.mrb を storage に焼き込む (picomodem 不要 deploy)

storage partition は littlefs (`R2P2-ESP32/main/CMakeLists.txt` の `littlefs_create_partition_image(storage ../storage FLASH_IN_PROJECT)`)。`R2P2-ESP32/storage/` 配下がデバイス FS root になり、`storage/home/` → `/home/` にマップされる。littlefs image は `idf.py build` 毎にディスクから再生成され、`idf.py flash` が `storage.bin` を 0x210000 に焼く。

→ `app.rb` を picorbc compile して `R2P2-ESP32/storage/home/app.mrb` に置けば、`/home/app.mrb` autostart payload として firmware と一緒に焼ける。**picomodem (runtime USB upload) 不要**。`rake r2p2:build_flash_appmrb SRC=...` がこれを実行 (reset はしない — esptool が自前で hard-reset するので boot capture が monitor guard と競合しない)。

**常用しない (flash 寿命)**: build_flash_appmrb は毎回 firmware (約 2MB) + storage (1MB) を全書き込みするので flash 消耗が大きい。app だけ変えた iteration では picomodem upload (storage に app.mrb のみ ~16KB 書込) の方が flash に優しい。build_flash_appmrb を default にせず、**mrbgem / firmware 自体を頻繁に変える開発 (どのみち full flash が要る)** に限定する。日常の app-only iteration は picomodem 経路 (`/stackchan-device-iterate` 等) を default にする。

**USB 抜き差しは build_flash_appmrb を選ぶ理由にならない**: picomodem は自分で reset を打ち shell banner を待つので人間の物理操作を要さない (2026-07-31 実測、ケーブルに触れずに 5/5 連続成功)。抜き差しが要るのはボードが USB から列挙されなくなった時だけで、その時は build_flash_appmrb も同じく使えない。

**注意 (Phase C)**: `storage/home/app.mrb` は R2P2-ESP32 fork tree に untracked で残る。app 固有の build 成果物なので R2P2-ESP32 PR には含めない (`.gitignore` に `storage/home/*.mrb` を検討)。

**boot capture の落とし穴**: `bin/capture-with-pty ... rake r2p2:monitor` の teardown (timeout で idf_monitor が port close) は chip を `boot:0x20 DOWNLOAD(USB/UART0)` モードに残す (log 末尾 `waiting for download`)。これは crash ではなく、app は teardown 前に cold-boot 完走している。clean な RTS-only reset (`dtr=False; rts=True→False`, `exclusive=False`) で app が正常 boot する。

### Recovery

See `stackchan-device-cold-recovery` / `-full-rebuild` skills and the
README recovery section.

**autostart 中の Ctrl-C で shell プロンプトは戻らない**: R2P2 は `/home/app.mrb` autostart に SIGINT を投げると main_task が return するだけで shell prompt は出ず、raw serial 経由の blind `rm` recovery は不可。`rake r2p2:wipe_storage` (esptool partition erase、~7s) を使う。

**esptool の erase offset は firmware (partition table) ごとに違う、暗記した値を他 repo/他 session へ使い回さない**: storage/partition の erase は必ず `rake r2p2:wipe_storage` (このリポジトリの Rakefile に正しい offset `0x410000` が埋め込み済み) を通す。別の R2P2-ESP32 branch/repo (例: partition レイアウトが違う実験用 fork) で使った offset をそのまま `esptool erase_region` に手打ちすると、factory app パーティションの中間を破壊してブートループを起こす (2026-08-20 発生、`0x210000` を誤用して被弾、`rake r2p2:full_rebuild` で復旧)。

### R2P2 shell REPL は二段構成

CoreS3 起動直後に出る `$>` は POSIX 風 shell プロンプトで Ruby 式は通らない (`p Foo` は command not found)。Ruby 評価は `irb` コマンドで REPL に入って `irb>` プロンプトに切り替えてから。動作確認スクリプトを送るときは必ず `irb` 経由で。

### ロングバッチ (rake は適用外)

`r2p2:setup` (10〜20 分) や `r2p2:build_flash` (5〜10 分) は `~/dev/src/CLAUDE.md` の 2 分超ロングバッチ規約に通常該当するが、**本プロジェクトでは上記「rake は subagent foreground で 1 個ずつ」が override する**。screen -dmS は使わず subagent (haiku) 表起動で大きい timeout (600000ms+) を設定。

rake 以外の長時間 batch job (大量 LLM ループ、SDK ingest 等) には引き続き `~/dev/src/CLAUDE.md` の `screen -dmS` + `DONE:` sentinel pattern が適用される。
