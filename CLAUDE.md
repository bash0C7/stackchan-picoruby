# stackchan-picoruby

StackChan (M5Stack CoreS3 の StackChan AI デスクトップロボット) を PicoRuby / R2P2-ESP32 で動かす個人プロジェクト。
何ができるか・セットアップ・既知の問題は `README.md`、現在地は `HANDOFF.md`。このファイルは「この repo で作業する時の約束事」だけを書く。

## 作業の進め方

- 頼まれた範囲をそのまま作る。付随する refactor・抽象化・将来のための保険は足さない。動く最小の形でよい。
- 質問・相談・思考の吐き出しには判断を返して止まる。修正は頼まれてから。
- 進捗報告はツール結果に裏付けのあることだけ書く。未検証は未検証と言う。
- 実機・ビルド・deploy は `stackchan-device-*` skill 経由。`rake r2p2:*` を main context から直接叩かない。
- 長い rake (setup / build_flash / full_rebuild) は subagent (haiku) の foreground で 1 chain task として回し、log は `/tmp/stackchan-picoruby-debug/` に tee する。
- 記事・WIP メモ・進捗は esa (team `ksbrb`、カテゴリ `ｽﾀｯｸﾁｬﾝ`) に置く。spec / plan は `docs/` 配下に置き、commit する。
- 日付・経緯・「以前は」を doc やコメントに残さない。現在の挙動を現在形で書く。経緯は git log に任せる。

## PicoRuby らしさ

コードとファイル配置は [picoruby/picoruby](https://github.com/picoruby/picoruby) の mrbgems を手本にする。

- gem は `mrbgem.rake` + `mrblib/<gem>.rb` (+ `mrblib/<gem>/*.rb`) + `test/*_test.rb`。`mrblib` 内で sibling を `require` しない (build が全部 bundle する)。cross-gem の `require 'ble'` 等だけ書く。
- on-device の `require` 名は gem 名から `picoruby-` を落とした hyphen 形 (`require 'stackchan-protocol'`)。
- テストは picotest (`Picotest::Test` サブクラス、`test/*_test.rb`)。CRuby の test-unit は host-only ツール (`test-host/`) にだけ使う。
- 仕様が分からない時は `chiebukuro_query_ruby_knowledge` → 無ければ `vendor/R2P2-ESP32/components/picoruby-esp32/picoruby` を読む。「禁止メソッド」を推測で決めない。

### 実測で確認済みの CRuby との差

- `rescue` 節の裸の `raise` は元例外を再送出しない。`rescue Foo => e` … `raise e` と書く。
- mruby VM を回す FreeRTOS task の stack は 8 KB。C から block を yield する構文 (`Array.new(n) { }`、`String#dup` 等) は VM を 1 段ネストして約 3.1 KB 積む。描画・BLE の深い経路では `while` と C 実装メソッドで書く。症状は `stack overflow in task picoruby_task` の boot loop。host では再現しない。
- `String#[]=` のコストは差し込み先の全長に比例する。大きな buffer に行ごとに差し込まない。host では見えない。

## 構成

- Firmware (`build_flash` が必要): LCD / PY32 / servo / `StackchanProtocol::FrameParser` の gem。R2P2-ESP32 の build_config が GitHub から fetch する。
- Driver gems (`mrbgems/picoruby-{stackchan-led,si12t,aw88298}`): この repo 内の mrbgem。firmware には入れず、Rakefile が `app.mrb` compile 時に application.rb の前に連結する。firmware 側に移す時は build_config に足して連結を外す。
- Application (`app/application.rb`、`upload_appmrb` で deploy): 顔・dispatcher・BLE・cold-boot。1 ファイルのまま維持する。テストは prism で class 本体だけ抽出する (`lib/ruby_class_extract.rb`) ので、class body の top-level に `< BLE` 以外の device-only 参照を置かない。
- PC (`pc/stackchan-pico`): PicoRuby の CLI `stackchan <verb>` + launchd daemon (BLE central)。AI と TTS は CRuby sidecar (`pc/sidecar`) に隔離し dRuby で橋渡し。
- 核心は **BLE 経由でサーボに絶対位置 (normalized 0..100 + 方向 key) を指定して期待通り動かすこと**。Face / LED / blink は装飾。

## ハードウェア (CoreS3)

ESP32-S3 / 16MB Flash / 8MB **Quad** PSRAM、ILI9342 320×240、WS2812 ×12、AXP2101 PMIC、AW9523 + PY32 IO expander、BMI270 + BMM150、LTR-553、GC0308、フィードバックサーボ ×2、Si12T 頭タッチ 3 zone、AW88298 + 1W speaker、PCF8563 RTC、microSD、NFC。
ピン配置と初期化順は公式ファームウェア `../StackChan` (`firmware/main/hal/board/`、`hal/drivers/`) を読んで参照する。書き込まない。

### cold-boot 初期化 (LCD と WS2812 を確実に出す順)

system I2C (SDA=12 / SCL=11) で:

1. AXP2101 @0x34 — `0x97 0x69 0x30 0x90 0x94 0x95 0x27 0x99` を全部書く。`0x90=0xBF` だけでは backlight が立たない。
2. AW9523 @0x58 — P0 output `0b00000111` (WS2812 5V rail)、P1 `0x81 → 20ms → 0x83` (LCD reset)。順序は P0 → P1 → CONFIG_P0 → CONFIG_P1 → GCR → LEDMODE_P0 → LEDMODE_P1。
3. PY32 — GPIO0 (VM_EN) HIGH + 200ms、GPIO13 (WS2812 data) push-pull。`refresh_leds` は read-modify-write。
4. ILI9342 の `rst_pin` / `bl_pin` は expander 経由なので未配線 GPIO を渡す。
5. cold-boot 後 `sleep_ms 3000` で必ず yield してから `BLE.new` → `start`。yield しないと advertising が RF に出ない (log は正常に見える)。

`application.rb` の PY32 init 区間の `puts` (`# REQUIRED FOR PY32 COLD-BOOT` マーカー) は削除禁止。bytecode layout 依存の crash を抑えている。

## BLE プロトコル

- yaw: `<YL:0..100>` / `<YR:0..100>` (排他、YL 優先)、pitch: `<PU:0..100>` (上のみ)、timing: `<T:ms>` か `<V:speed>` のどちらか。
- 稀: `<torque:on|off>`、`<selftest:run>`、`<read:pos>` (`calibrate` だけが使う)。
- cold-boot は torque OFF + `Face::Closed`。操作者が正面に合わせて `<torque:on>`。
- 位置コマンドの detail `<YL_actual:N,PU_actual:N>` は **受信時点の姿勢** (移動後ではない)。`unknown` = キャリブレーション要。移動後の値が要るなら `<read:pos>`。
- audio は半二重: `<A:N>` → device `<A:ready>` → `T = N*1000/8000 + 3000 ms` 静止 → RX queue drain → I2S 再生。PC は 1.5 s 待ってから blast、`N/8000 + 2 s` 待つ。
- CLI: `stackchan servo --yaw-left 50 --pitch-up 30 --time 500`、`stackchan torque on`、`stackchan calibrate --align-only`。exit 6 = calibration needed、7 = verify fail。

### BLE 実装 notes

- heartbeat tick は約 1 秒。Mac の idle 切断は 15〜20 秒なので 10 秒以内に notify か write を流す。
- event drain は「`pop` の結果に関わらず毎 tick `_event_popped` を呼ぶ」。`BLE#start` は override しない。
- Mac scan で見えない時は先に `sudo pkill bluetoothd`。別 central で再現するかで環境要因を切り分ける。
- BLE 検証中に serial monitor を並走させない (port open の DTR/RTS で device が reset する)。
- Mac の BLE は `stackchan` CLI で自律実行する。人に iPhone を頼まない。CoreBluetooth は TCC 経由なので daemon は `rake pc:up` (launchd + `~/Applications/StackchanPico.app`) からしか動かない。`pc:vm_build` の後は `pc:app_bundle` を再実行。
- btstack/NimBLE thread と main task が同時に mruby heap を触ると crash する。device 側の cross-thread 対策は `picoruby-ble-bridge` gem。
- レイテンシは同一セッション内の 2 点でしか比較しない (セッション間で 15〜25% ぶれる)。描画コストは primitive 数に比例し、`SPI#write` 回数では説明できない。計測は `tools/latency_baseline.zsh` + `tools/latency_summary.rb`、face 別は `tools/face_profile.zsh`。device 側に一時 `puts` を足さない (boot loop に入る)。

## テスト

```
bundle exec rake test                 # picotest: device / pc / shared + 各 driver gem (host picoruby VM)
SUITE=pc FILTER=stackchan_central bundle exec rake test
bundle exec rake test:host            # CRuby-only tools (test-host/)
bundle exec rake picotest:build       # host VM 再 build。firmware build の後は必ず (症状: uninitialized constant Picotest)
```

- device suite は fakes (`test/fake_*.rb`) + stub (`test/picotest/stubs.rb`) + 抽出した application class + scservo source を VM に注入する (`test/picotest/harness.rb`)。
- pc suite は `ble_client.rb` を同様に抽出し、`test/pc/stubs.rb` の `BLE` stub と `test/pc/fake_radio.rb` で回す。`PICOTEST_VM=` で別 VM。
- face geometry golden は `spec/golden/face_<name>.dump`。更新は `rake face:register_golden FACE=<name>`。
- picoruby-scservo は firmware build が fetch する。build 前は `SCSERVO_RB=` で clone を指す。

## ビルド・deploy

| 用途 | 手段 |
|---|---|
| app だけ変えた | `/stackchan-device-iterate` (picomodem upload、flash に優しい) |
| firmware / gem / sdkconfig を変えた | `/stackchan-device-build-flash` → `/stackchan-device-cold-recovery`、または `/stackchan-device-full-rebuild` |
| 初回・target 切替 | `/stackchan-device-setup` |
| 復旧 | cold-recovery → full-rebuild → 人手 (USB 抜き差し / download mode) |

- `.rb` の直接 upload は禁止。必ず host で picorbc compile した `.mrb` を上げる (on-device compile は codegen stack overflow)。
- firmware build は必ず clean build (`clean_picoruby_build` 依存を外さない)。undefined symbol が出たら source tree を grep し、無ければ object の陳腐化。
- `build_config/xtensa-esp-picoruby.rb` に gem を足したら `r2p2:setup` が必要。`conf.gem github:` の gem は `build/repos/` に cache され pull されない。gem を直したら `git -C <その path> log -1` で確認し、違えば `rm -rf` してから build。
- sdkconfig fragment を編集しても `idf.py build` は再適用しない。`ensure_sdkconfig_fresh` が rake 側で処理する。CoreS3 は `sdkconfigs/cores3` (Quad PSRAM)。BLE-only build は coex を全部 `n` にしないと `coex_schm_lock` で panic する。
- `idf.py flash` は storage 区画も焼くので `/home/app.mrb` が消える。flash 後は upload し直す。
- storage erase は `rake r2p2:wipe_storage` を通す (offset は partition table 依存、手打ちしない)。
- autostart 中の Ctrl-C で shell は戻らない。wipe で復旧する。
- serial port を触る rake は `ensure_no_concurrent_monitor` を呼ぶ。serial capture は `bin/capture-with-pty`、生 `cat` は禁止。
- boot 失敗は cold-boot 全体の log を取り `LoadError|cannot load|NameError|Guru Meditation` を最初の異常から読む。
- picoruby-uart: unit は `:ESP32_UART0..2`、`write` は String のみ、`read` は timeout を無視するので `readpartial` で poll。
- R2P2 の `$>` は POSIX 風 shell。Ruby 式は `irb` に入ってから。

## picoruby-ble の lineage を乗り換える時

個別 fix の cherry-pick ではなく gem 本体 (`mrblib/ src/ include/ sig/ mrbgem.rake` + `ports/esp32/{ble,ble_central,ble_peripheral,nimble_owner}.[ch]`) を丸ごと持ってくる。`mruby-task` の `mrb_task_queue_push` が要るので submodule `mruby/mruby` の sha を合わせる。`_event_popped` / `_event_queue_cleared` / `@event_queue` / `hci_power_control` の名前と可視性を grep で確認し、compile が通っても `ble_control_smoke` / `ble_servo_smoke` / `ble_torque_smoke` を実機で通すまで完了としない。
