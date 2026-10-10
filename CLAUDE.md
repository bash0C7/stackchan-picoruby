# stackchan-picoruby

StackChan (M5Stack CoreS3 の StackChan AI デスクトップロボット) を PicoRuby / R2P2-ESP32 で動かす個人プロジェクト。
何ができるか・セットアップ・既知の問題は `README.md`、現在地は `HANDOFF.md`。このファイルは「この repo で作業する時の約束事」だけを書く。

## 作業の進め方

- 頼まれた範囲をそのまま作る。付随する refactor・抽象化・将来のための保険は足さない。動く最小の形でよい。
- 質問・相談・思考の吐き出しには判断を返して止まる。修正は頼まれてから。
- 進捗報告はツール結果に裏付けのあることだけ書く。未検証は未検証と言う。
- 実機・ビルド・deploy は `stackchan-device-*` skill 経由。`rake r2p2:*` を main context から直接叩かない。
- 長い rake (setup / build_flash / full_rebuild) は subagent (haiku) の foreground で 1 chain task として回し、log は `/tmp/stackchan-picoruby-debug/` に tee する。
- spec と plan は repo の `docs/superpowers/{specs,plans}/` に置いて commit する。review・調査レポート・計測の証拠は Obsidian vault の `~/Library/Mobile Documents/iCloud~md~obsidian/Documents/ObsidianVault/02_dev_docs/stackchan-picoruby/review/` に置く。PR #427 関連は隣の `picoruby-ble-esp32-port/`。記事・WIP メモは esa (team `ksbrb`、カテゴリ `ｽﾀｯｸﾁｬﾝ`)。
- 日付・経緯・「以前は」を doc やコメントに残さない。現在の挙動を現在形で書く。経緯は git log に任せる。
- コメントを書かない。コードは How、テストは What (テスト名)、コミットログは Why を担う。残すのは toolchain が読むもの (magic comment、suppify の `#:` 型注釈、rigor/steep 指示) と `# REQUIRED FOR PY32 COLD-BOOT` だけ。

## 検証と報告の規律

- **読んだ数値やファイルが、検証対象が生んだものか確かめる。** exit code を主張するなら pipe を外すか `set -o pipefail` / `${PIPESTATUS[0]}` を使う (`tee` は常に 0 を返す)。出力ファイルを読む前に mtime を見る。`cd` した後の相対パスは壊れると考える。stderr を捨てたまま成否を判定しない。subagent に走らせる時は「rake 本体の exit code を報告せよ」と prompt に書く。
- **完了を主張する前に、その機能が実際に使われる形で 1 回動かして出力を見る。** hook なら実 `git push` を撃つ。sha の到達性なら remote に問う。branch ref の存在確認・script の単体叩き・remote-tracking ref は代理であって本物ではない。実行できない経路は「未検証」と名指しする。
- **host で回帰検出できない箇所を「実機で確認する」に倒さない。** BLE 等の実体は薄い adapter に隔離してロジックを素の class に出し、無い harness / fake は新設する。実機のみで確認する範囲は adapter の数行に限定する。
- 指摘を 1 件受けたら、その 1 箇所を当てて終わりにしない。一般原因を 1 行で言語化し、目的から全体を導出し直す。

## PicoRuby らしさ

コードとファイル配置は [picoruby/picoruby](https://github.com/picoruby/picoruby) の mrbgems を手本にする。

- gem は `mrbgem.rake` + `mrblib/<gem>.rb` (+ `mrblib/<gem>/*.rb`) + `test/*_test.rb`。例外は `stackchan-robot` と `stackchan-controller` で、test は repo の `test/device` と `test/pc` に置く。`mrblib` 内で sibling を `require` しない (build が全部 bundle する)。cross-gem の `require 'ble'` 等だけ書く。
- on-device の `require` 名は gem 名から `picoruby-` を落とした hyphen 形 (`require 'stackchan-protocol'`)。
- テストは picotest (`Picotest::Test` サブクラス、`test/*_test.rb`)。CRuby の test-unit は host-only ツール (`test-host/`) にだけ使う。
- 仕様が分からない時は `chiebukuro_query_ruby_knowledge` → 無ければ `vendor/R2P2-ESP32/components/picoruby-esp32/picoruby` を読む。「禁止メソッド」を推測で決めない。
- 複数 port を持つ gem (picoruby-ble の rp2040 と esp32 等) を触る時、従の port の仕事は `include/*.h` の契約に conform することだけ。ログ・説明コメント・観測性のような「一般に良いとされる」上乗せは、主の port に無ければ従にも置かない (既存分も消す)。契約自体の是非や主 port や共有層への論評は範囲外で、adversarial review がそこを叫んでも採らない。既存契約を従が自分の中で守れていない場合の是正は別で、これは必要。

### 実測で確認済みの CRuby との差

- `rescue` 節の裸の `raise` は元例外を再送出しない。`rescue Foo => e` … `raise e` と書く。
- mruby VM を回す FreeRTOS task の stack は 8 KB。C から block を yield する構文 (`Array.new(n) { }`、`String#dup` 等) は VM を 1 段ネストして約 3.1 KB 積む。描画・BLE の深い経路では `while` と C 実装メソッドで書く。症状は `stack overflow in task picoruby_task` の boot loop。host では再現しない。
- 例外は 1 回の raise + rescue で C stack を約 1.8 KB 積む (QEMU で `Machine.stack_high_water_mark` が 2024 B → 184 B)。起動後の空きは約 2 KB しかないので、tick と BLE の経路で raise を流れの制御に使わない (`DRbBle::Responder#feed` は長さ付きメッセージを切り出して、揃ってから読む)。
- `String#[]=` のコストは差し込み先の全長に比例する。大きな buffer に行ごとに差し込まない。host では見えない。
- `send` / `__send__` は、相手が定義していない method (`method_missing` で受けるもの。`DRb::DRbObject` が典型) を C の関数呼び出しで実行する。その内側の `sleep_ms` は task を切り替えない待ちになり、`Task.pass` は `can't pass across C function boundary` を raise する。Mac の BLE 通知は scheduler の入口でしか event queue に移らないので、robot は命令を実行しているのに reply が見えず 3 s で timeout する。DRb の front を名前で呼ぶ時は `DRb.send_message` を使う (`Central#call_front`)。名前で呼ばれる側 (iOS / watchOS の bridge が `App.__send__` で呼ぶ controller) は、その名前を実 method として定義する。host では `Task.pass` する radio (`test/pc/passing_radio.rb`) で検出する。
- `Task.new` の block は `self` がトップレベルの `main` で走る (block を作った場所の `self` ではない)。block が使う receiver や instance 変数は先に local に取ってから block に渡す (`Daemon#start_tick` / `#stop`)。

## 構成

StackChan を知っているのはこの repo だけ。picoruby・R2P2-ESP32・R2P2-darwin・driver の gem repo (picoruby-ili9342 / picoruby-py32-io-expander / picoruby-scservo)・suppify はどの project にも仕える横断の層で、StackChan かどうかを問わない。StackChan 固有のもの (gem の組み合わせ、pin 配置、app、protocol、名前) はこの repo の `build_config/`・`mrbgems/`・`apps/` に置き、横断の層へは「platform が決めた契約 (build_config の受け口、`APP_DIR` 等の env、HAL や port の header) に conform する」形でだけ関わる。横断の層に直すべきものが見つかったら、StackChan を外しても成り立つ一般の修正としてその repo に出す。

- Firmware (`build_flash` が必要): firmware の gem 一覧は `build_config/esp32-stackchan.rb` にあり、`r2p2_build_env` が `R2P2_BUILD_CONFIG` (絶対 path) として R2P2-ESP32 に渡す。LCD / PY32 / servo の gem はこの config の `conf.gem github:` で fetch し、protocol gem (`StackchanProtocol::FrameParser` / `FrameCodec` / `FrameText`、`mrbgems/picoruby-stackchan-protocol`)・AOT kernel・picoruby-multicore は gem dir で入れる。picoruby-multicore の `ports/esp32/multicore.c` は ESP-IDF の include が要るので `R2P2_EXTRA_SRCS` で IDF component の source に足す。R2P2-ESP32 自身の default config は StackChan の gem を持たない。
- Driver gems (`mrbgems/picoruby-*`): この repo 内の mrbgem。どれも pure Ruby で、`stackchan-led` / `si12t` / `aw88298` / `drb-ble` / `stackchan-robot` は Rakefile が `app.mrb` compile 時に app の前に連結する (先頭に app の top-level `require` を置く)。`stackchan-controller` は firmware に入らず、Mac の daemon / CLI は source で `load` し、iOS / watchOS は VM に gem として build する (依存は `mrbgem.rake` に宣言し、mrblib は build と同じ sort 順で読める)。
- AOT kernels (`aot/kernels/*.rb`): spinel → suppify で 1 つの mrbgem にして firmware に入れる Ruby。`ulaw_decode` は picoruby-multicore で core 1、`glyph16` は core 0 から直接呼ぶ。spinel runtime は 1 組で thread-safe でないので、core 1 の kernel 実行中に core 0 で kernel を呼ばない。手順と制約は `aot/README.md`。
- Application (`apps/robot/app.rb`、`upload_appmrb` で deploy): `require` 列と `StackChan.robot do |bot| … end.run` 1 つだけの DSL ファイル。顔の定義・face index・touch 反応・周期処理・`release_after`・`on_boot`・`on_frame`・`remote` handler を書く。`$` とトップレベルの `@` と定数は置かない。
- Robot engine (`mrbgems/picoruby-stackchan-robot`): DSL (`StackChan.robot` / `Builder`)、cold-boot (`StackChan::Robot::Boot`)、BLE peripheral (`StackChan::Robot::Peripheral < BLE`)、dispatcher・ticker・audio・dRuby front。`Robot#run` は `serve(Boot, Peripheral)` で、`sleep_ms 5000` → boot → `sleep_ms 3000` → peripheral → on_boot handler → advertise の順に進み戻らない (順序は `test/device/robot_run_test.rb` が fake で固定する)。class body で device 定数 (`ILI9342` / `I2C` / `BLE` 等) を読まない。例外は `peripheral.rb` の `< BLE` だけで、host の device suite はこの 1 ファイルを読まない。
- Mac application (`apps/mac/app.rb`): `App = StackChan.controller do |c| … end` 1 つだけの DSL ファイル。`c.action` が CLI の verb になり (`face` / `led` / `servo` / `torque` / `selftest` / `say` / `chat` / `demo`)、`c.hold` と `c.on_reply` を書く。
- Apple applications (`apps/ios`, `apps/watchos`): `app.rb` は `App = StackChan.controller do |c| … end` 1 つだけ。bridge は `App.__send__(method, String)` を呼んで stdout を返すだけなので、controller は最初の call で platform の central に自分で wire し、`actions` は引数付きで呼ばれると `name<TAB>label` を 1 action 1 行で出す。Swift (`Sources/`) はその行から 1 action 1 ボタンを作り (`connect` は toolbar、`stop` は出さない)、iOS は text field の中身を引数に渡し、Speak は AVSpeech の μ-law hex を built-in `speak_audio` に渡す。bridge は 1 s ごとに `tick` を呼ぶ。`-StackchanBatch "<verb args>;…"` で起動すると VM が開いた後に各行を順に呼び、出力の各行を `[batch] <line>`、最後に `[batch] end` を出して exit 0。VM は `build_config/darwin-stackchan-{ios,watchos}-{sim,device}.rb` (この repo の gem を path で入れる)、Mac VM は `build_config/darwin-stackchan-pc.rb`。`rake ios:*` / `watchos:*` が `vendor/R2P2-darwin` の `<platform>:app:*` を `APP_DIR` 等の env で呼び、`project.yml` は platform を `${R2P2_DARWIN}` で指す。Simulator での build と起動は `/stackchan-apple-simulator` (VM と project は rake、build・起動・console は `.mcp.json` の Xcode MCP)。`rake ios:run` (と `ios:all`) は `open -a Simulator` で止まる。
- Controller engine (`mrbgems/picoruby-stackchan-controller`): `StackChan.controller` DSL (`Builder` / `Args`)、BLE central (`Nus` / `Radio` / `Central`)、link の状態機械 (`Link`: `released → held → quiet`、接続できなければ `busy`)、`Session` (verb・touch・reply)、`Daemon` (action table を dRuby front に出す)、`CLI`、`Calibration`、`SendBuilder` と error 階層。engine の built-in action は `connect` / `status` / `stop` / `raw` / `calibrate` / `speak_audio` (`Controller::BUILTINS`)。`remote` / `touch` / `tui` は CLI にだけある verb (`CLI::BUILTIN_VERBS`)。
- PC glue (`pc/stackchan-pico`): launchd と process の接着だけ。`boot_daemon.rb` が controller gem と `apps/mac/app.rb` を source で `load` して `App.serve`、`boot_cli.rb` が `cli.rb` と `calibration.rb` だけを `load` して CLI を起動、`bin/stackchan`、app bundle の Info.plist (`StackchanPico-Info.plist`。launchd の plist は `lib/launch_agent.rb` が生成する)、`fake_ble.rb` (`BLE_FAKE=1`)、`drb_eintr_retry.rb`。AI と TTS は CRuby sidecar (`pc/sidecar`) に隔離し dRuby で橋渡し。
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

`mrbgems/picoruby-stackchan-robot/mrblib/stackchan-robot/boot.rb` の PY32 init 区間の `puts` (`# REQUIRED FOR PY32 COLD-BOOT` マーカー) は削除禁止。bytecode layout 依存の crash を抑えている。

SPI 転送は 1 回 4092 byte が上限。picoruby-spi の ESP32 port は bus を `max_transfer_sz`
未指定 + DMA 有効で作るので、esp_driver_spi が DMA descriptor 1 個分で頭打ちにする。超えると
`IOError: SPI write failed` になる。host の fake では再現しない。

## BLE プロトコル

- controller と robot の間の命令・応答・頭タッチは全部 dRuby over BLE を通る。NUS の第 1 pair (`6e400002` write / `6e400003` notify) に残るのは音声の直接経路だけ。
- frame の語彙 (dRuby の `command` に渡す Hash の key、CLI の `raw` verb が受ける文字列): yaw: `<YL:0..100>` / `<YR:0..100>` (排他、YL 優先)、pitch: `<PU:0..100>` (上のみ)、timing: `<T:ms>` か `<V:speed>` のどちらか。
- 稀: `<torque:on|off>`、`<selftest:run>`、`<read:pos>` (`calibrate` が使う)。
- dRuby over BLE: NUS service 内の第 2 pair (`6e400004` write / `6e400005` notify) に DRb の TCP stream をそのまま 180 B chunk で流す (`mrbgems/picoruby-drb-ble`)。front は `StackChan::Robot::Remote` で、`command` / `servo` / `led` / `face` / `text` / `torque` / `read_pos` / `selftest` は frame の Hash を `Dispatcher#handle_to` に渡し、行の Array を返す (1 行目が `.\n` か `?\n`、あれば 2 行目が detail)。`touches` は前回の呼び出しから溜まった頭タッチの zone の Array (上限 16) を返して空にする。`stack_free`・`servo_health` (servo ごとの直近の read の失敗理由と status byte)・音声の `audio_begin` / `audio_chunk` / `audio_play` / `audio_done`・`bot.remote` の handler は `Dispatcher` を通らない。4096 B を超える request は捨てる (`DRbBle::Responder::MAX_REQUEST`)。controller の reply 待ちは 3 s で、超えたら `TimeoutError`、1 行目が `?\n` か robot 側の例外なら `DeviceError` (`Central#remote_call`)。`Session` と app の action は `Central#send` / `raw_send` が frame の文字列を `FrameParser` で Hash に戻して `command` を呼ぶ。CLI の `remote` verb (`stackchan remote servo YL=50 PU=30 T=500`) は front を直接呼ぶ口で、1 行目が `?` なら exit 1。`picoruby-drb` と `picoruby-multicore` は `build_config/esp32-stackchan.rb` に入っている。
- cold-boot は torque OFF + `Face::Closed`。操作者が正面に合わせて `<torque:on>`。
- 位置コマンドの detail `<YL_actual:N,PU_actual:N>` (右向きなら `<YR_actual:N,PU_actual:N>`) は **受信時点の姿勢** (移動後ではない)。`unknown` = キャリブレーション要。移動後の値が要るなら `<read:pos>` (raw 値の `<yaw_raw:N,pitch_raw:N>` を返す) を使うか、次の位置コマンドの detail を読む。CLI の `raw` verb は device の detail を捨てて `OK raw` しか返さないので、`stackchan raw '<read:pos>'` では値が取れない。
- audio の直接経路 (既定) は半二重: `<A:N>` → device `<A:ready>` → `T = N*1000/8000 + 3000 ms` の間 50 ms ごとに RX を drain して溜める → I2S 再生 → `<A:done>`。PC は `<A:N>` の後 1.5 s 固定で待ち (`READY_WAIT_MS`、`<A:ready>` は待たない)、180 B の write を 20 ms 間隔で送り、`<A:done>` を `3300 + N*6/5` ms (30 s〜180 s に clamp) まで待つ (`Session#speak_audio`、`Central#await_audio_done`)。 dRuby 経路 (`Session#speak_audio(ulaw, route: :drb)`、Mac の `say --drb`) は `audio_begin` → 2048 B ずつ `audio_chunk` → `audio_play` (予約だけして返り、robot は reply を出し終えた次の `LinkLoop#tick` で再生する) → 再生時間ぶん待って `audio_done` を 500 ms ごとに問う。どちらを残すかは実機の計測で決める (`docs/superpowers/specs/2026-10-10-druby-single-route-design.md`)。robot の NUS RX は `<A:N>` とそれに続く byte 列以外の frame に `?` を返す。
- CLI: `stackchan servo --yaw-left 50 --pitch-up 30 --time 500`、`stackchan torque on`、`stackchan calibrate --align-only`。送れる face 名は `angry / joy / neutral / sad / smile / surprised` (`FrameCodec::FACE_INDICES`)。`closed` は BLE の index を持たず、`<torque:off>` で出る。exit 6 = calibration needed、7 = verify fail、8 = busy (robot が別の central に握られているか届かない。次の action でだけ再接続を試す)。`stackchan status` は `link=held connects=1 releases=0 last_connect_ms=… hold_ms=10000 ble_connected=true …` の key=value 1 行。`stackchan touch listen --count N --timeout SEC` は `touch zone=N (back|right|left)` を出し、N 回で exit 0、timeout か link 解放で exit 1。

### BLE 実装 notes

- 周期: robot の link loop は 20 ms (`LinkLoop::TICK_MS`)、touch と LED の poll は 50 ms (`Ticker`)、Mac daemon の tick は 250 ms (`Daemon::TICK_MS`)、iOS / watchOS は 1 s。robot は RX・CCCD write・dRuby の通信が `release_after` (15 s) 無ければ central を切る。
- controller は link を使う間だけ握る。最初の action で接続して `held`、held の間だけ 1 s ごとに `touches` を呼ぶ keepalive (返った zone が頭タッチの通知になる)、最後の action から `c.hold` ms で `quiet` (keepalive を止め、robot の release を待つ)。切断 packet (`[0x3E,0x01,0x05]`) を drain で見たら `released` にし、次の action が再接続する。接続できなければ `busy` (exit 8) で、再試行は次の action まで待つ。link が生きたままの ACK timeout は link を捨てない。keepalive の ACK timeout で link の喪失が分かっていなければ `quiet` に移る。`touch listen` の poll 中は hold を延長する。
- connect は NUS TX と dRuby TX の両方の CCCD を要求する。discovery がどちらかを見つける前に終わると `ConnectionError` になり、link は `busy` (exit 8) を返す (`Central#resolve_handles`)。
- event drain は「`pop` の結果に関わらず毎 tick `_event_popped` を呼ぶ」。`BLE#start` は override しない。
- Mac scan で見えない時は先に `sudo pkill bluetoothd`。別 central で再現するかで環境要因を切り分ける。
- robot の GATT 表は末尾に Service Changed (`0x1801` / `0x2A05` indicate) を持つ。bond しない central は接続のたびに discovery し直す前提で、indication は送らない。Mac が古い表を使い続ける時は `sudo pkill bluetoothd` で捨てる。
- BLE 検証中に serial monitor を並走させない (port open の DTR/RTS で device が reset する)。
- Mac の BLE は `stackchan` CLI で自律実行する。人に iPhone を頼まない。CoreBluetooth は TCC 経由なので daemon は `rake pc:up` (launchd + `~/Applications/StackchanPico.app`) からしか動かない。`pc:vm_build` の後は `pc:app_bundle` を再実行。
- btstack/NimBLE thread と main task が同時に mruby heap を触ると crash する。device の main task は BLE のデータを picoruby-ble の event queue の `pop` と `pop_write_value` からだけ受け取る (`peripheral.rb`)。
- レイテンシは同一セッション内の 2 点でしか比較しない (セッション間で 15〜25% ぶれる)。描画コストは primitive 数に比例し、`SPI#write` 回数では説明できない。計測は `tools/latency_baseline.zsh` + `tools/latency_summary.rb`、face 別は `tools/face_profile.zsh`。

### launchd (`rake pc:up` / `lib/pc_lifecycle.rb`) の実測挙動

推測で書くと静かに壊れる。触る前にここを読む。

- `launchctl kickstart -k` は書き直した plist を読み直さない。launchd は bootstrap 時に定義を in-memory に取り込むので、設定を変えたら必ず `bootout` + `bootstrap`。kickstart 経路を残すと前日の設定で起動して成功と表示する。
- `bootout` は unload 完了前に返る。ポートが空くのと service 登録が消えるのは別のシグナルで、ポートは数ミリ秒で空くのに登録は残る。`launchctl print` が失敗する (= 不在) まで待ってから bootstrap する。
- **daemon のポートを接続で確認しない。** `wait_for_port` が connect して即 close すると、見捨てられた接続が drb ポートに残る。daemon は起動中 (sidecar priming) にブロックしており、協調 Task なのでそれを処理できず、後で相手のいないソケットへ書いて SIGPIPE で死ぬ。このため `pc:up` は `lsof` で LISTEN を見るだけで接続しない。PicoRuby VM は SIGPIPE を trap できない (`Signal.list` に `PIPE` が無く、`Signal.trap` はどの形でも `SystemStackError`)。R2P2-darwin が引く picoruby の picoruby-socket は listen socket に `SO_NOSIGPIPE` を付けて accepted socket に継承させるので、切れた相手への send は EPIPE で例外になり、picoruby-drb はその client だけを捨てて accept を続ける。RST が accept より前に届いた socket には後から `setsockopt` できない (失敗する) ので、listen socket 側に付ける。
- `hal-task-darwin` (R2P2-darwin が引く picoruby の gem) は Mac の config (`build_config/darwin-stackchan-pc.rb`) にだけ入れる。iOS / watchOS の config には入れない (`bridge/task_hal_ios.c` と二重定義になる)。
- Ruby 4.0 は `drb` を default gem から外した。root の `Gemfile` に `gem 'drb'` が要る。host test は verifier を注入して本物の DRb 経路を通らないので、テストは緑のまま実機で LoadError になる。
- CoreBluetooth の許可 (TCC) は app の designated requirement に付く。`codesign -s -` だけの ad-hoc 署名では requirement が cdhash になり、`pc:vm_build` → `pc:app_bundle` で VM が変わるたびに別の app として扱われ、launchd から起動した daemon は許可ダイアログ待ちのまま scan 結果を 1 件も受け取らない (`no StackChan advertiser found`、状態通知も来ない)。Terminal から走らせた scan は Terminal の許可で動くので切り分けにならない。`pc:app_bundle` は requirement を `identifier "com.bash0c7.stackchanpico"` に固定して署名する。この Mac の Apple Development 証明書は全部失効している。

## テスト

```
bundle exec rake test                 # rigor:check の後に picotest: device / pc / aot / drb-ble / stackchan-protocol / stackchan-led / si12t / aw88298 (host picoruby VM)
SUITE=pc FILTER=central bundle exec rake test
bundle exec rake test:host            # CRuby-only tools (test-host/)
bundle exec rake picotest:build       # host VM 再 build (build_config/picoruby-test.rb)。picoruby を更新した後に
```

- device suite は fakes (`test/fake_*.rb`) + stub (`test/picotest/stubs.rb`) + robot gem の mrblib (`peripheral.rb` を除く) + scservo source + `apps/robot/app.rb` を VM に注入する (`test/picotest/harness.rb`)。app は CRuby 側で prism が top-level `require` を落とし、`RobotApp.robot` に包み、`StackChan::Robot#run` を self を返す stub に差し替えて読ませる (`test/device/app_test.rb` が fake に wire して検証する)。picoruby-drb は mrblib を source で、AOT kernel は `aot/kernels` の Ruby を、multicore は `test/fake_multicore.rb` を注入する。
- pc suite は controller gem (`mrbgems/picoruby-stackchan-controller`) の mrblib と `apps/mac/app.rb` をそのまま source で注入し (抽出も書き換えもしない)、`apps/ios/app.rb` / `apps/watchos/app.rb` は `ios_app_test.rb` / `watchos_app_test.rb` が `App` の定数名だけ変えて `load` し、`test/pc/stubs.rb` の stub と `test/pc/fake_radio.rb` の `FakeRadio` (link 切断・接続拒否を起こせる) / `FakeRobotRadio` で回す。時計は注入する。`PICOTEST_VM=` で別 VM。
- pc suite は CRuby と host VM の両方で走る。host VM には実物の `Task` があり、`DRb` は組み込まれていないので harness が picoruby-drb の mrblib を source で注入する。`Task` を stub するなら `unless Object.const_defined?(:Task)` で囲む。host VM の Task は picotest が yield しない限り body を走らせないので、両方で同じ観測になる。
- face geometry golden は `spec/golden/face_<name>.dump`。更新は `rake face:register_golden FACE=<name>`。
- picoruby-scservo は firmware build が fetch する。build 前は `SCSERVO_RB=` で clone を指す。
- host VM は `vendor/R2P2-ESP32/components/picoruby-esp32/picoruby/build/host-picotest` に建つ。R2P2-ESP32 自身の host ツールは同じ picoruby の `build/host` なので衝突しない。全 suite が `uninitialized constant Picotest` になったら、順序ではなく build 名の衝突を疑う。

## ビルド・deploy

- firmware・gem・app・BLE link を変える branch (この repo と、R2P2-ESP32 / picoruby-ili9342 / suppify / R2P2-darwin の対応 branch) は、`acceptance/lock.yml` に sha を書いて `/stackchan-device-acceptance` を通し、`acceptance/results/` の report が `verdict: pass` になるまで merge しない。
- 実機に載る firmware は信頼のおける 1 種類だけ。比較や確認のために別の firmware を焼かない。書き込みは firmware が変わった時の 1 回で、app の転送は別に何度でもよい。実機で落ちたら実機で試し直さず、boot log を証拠に QEMU (`r2p2:qemu_check`) か host で再現して直す。

| 用途 | 手段 |
|---|---|
| app だけ変えた | `/stackchan-device-iterate` (picomodem upload、flash に優しい) |
| iOS / watchOS app を変えた | Mac で `rake ios:device:all` / `watchos:device:all` (Simulator は `/stackchan-apple-simulator`)。`rake acceptance:darwin` は署名できる証明書がある時に任意で流す (verdict の条件ではない) |
| firmware / gem / sdkconfig を変えた | `/stackchan-device-build-flash` → `/stackchan-device-cold-recovery`、または `/stackchan-device-full-rebuild` |
| 初回・target 切替 | `/stackchan-device-setup` |
| 復旧 | `rake r2p2:boards` → cold-recovery → full-rebuild → 人手 (CoreS3 の USB serial が `r2p2:boards` に無い時だけ) |
| merge 前の実機実績 | `/stackchan-device-acceptance` (`acceptance/lock.yml` の firmware 1 種類を `acceptance:deploy` で 1 回だけ焼き、app は `acceptance:app` で別に何度でも送り、`acceptance:check` で書き込まずに何度でも確かめる。owner が TTY のある端末で `acceptance:check` を 1 回通しで流し、touch と問いもその中で済ませる) |

- firmware を焼く task (`r2p2:flash` / `build_flash` / `build_flash_appmrb`、それを呼ぶ `full_rebuild` と `acceptance:deploy`) と `acceptance:app` は先に `r2p2:qemu_check` を通す。同じ tree を UART console 付き QEMU で起動し、app の require・bundle した gem (robot engine の `Peripheral < BLE` を含む)・`run` を空にした `StackChan::Robot` で app ファイル全体 (`StackChan.robot` block の評価) を読ませたうえで boot log から verdict を出す。QEMU は `-icount shift=2,align=off,sleep=off -seed 1 -rtc clock=vm` で走らせるので、同じ image なら shell prompt までの serial 出力は毎回同じになり、verdict はそこまでの log だけで決まる。FAIL なら flash せず、PASS のあと clean build してから flash する。QEMU が見るのは boot・gem load・DSL の評価までで、cold-boot 本体・I2C デバイス・LCD・サーボ・スピーカー・BLE 無線は見ない (そこは `/stackchan-device-acceptance`)。
- `rake qemu:setup` は QEMU (`esp_develop_9.2.2_20250817`) を sha256 で pin して `build/qemu/` に展開する。macOS は `brew install libgcrypt glib pixman sdl2 libslirp` が要る。QEMU `9.0.0` は PSRAM を見つけない (`quad_psram: PSRAM ID read error`)。eFuse drive は `nvram.esp32s3.efuse` (`esp32c3.efuse` は QEMU 9.2.2 に拒否される) に `BLK_VERSION_MAJOR=1` (byte 64 = `0x01`) を乗せないと boot が eFuse チェックで spin する。build と gate の `PICORB_VM` は一致させる。
- `.rb` の直接 upload は禁止。必ず host で picorbc compile した `.mrb` を上げる (on-device compile は codegen stack overflow)。
- `main_task.rb` は `/home/app.mrb` を無条件に `load` し、このアプリは戻らないので `$shell.start` に到達しない。抜ける keypress も無い。`upload_appmrb` はこのため先に `wipe_storage` を通す。`upload_mrb` (`DST=`) は app.mrb を壊さずに wipe できないので、autostart 中の device への helper upload は wipe → helper → app.mrb の順になる。
- device 側に一時的な `puts` を足さない。cold boot で Guru Meditation の boot loop に入ることがあり (原因未特定、`Loading app.mrb` 直後で panic)、そうなると USB CDC が再列挙し続けて esptool も繋がらない。復旧は人間による USB 抜き差しだけで、抜き差し直後の 1 回しか esptool が通らないので、その 1 回を何に使うか決めてから頼む。
- smoke や upload の前に device の素性を確かめる。storage offset (`0x410000`) と `App version` は `rake r2p2:flash_identity` で flash から読む (read-only、板は reset する)。reset 後は USB Serial/JTAG が再列挙するので、boot log に bootloader の `Partition Table:` や `App version` が載るかは再接続の速さ次第で、そこからは判定しない。boot log では `[application] boot` / `[boot] step:` marker と fault を見る。違えば別 tree の firmware なので `/stackchan-device-full-rebuild`。実機への上書き deploy は承認済み。
- firmware build は必ず clean build (`clean_picoruby_build` 依存を外さない)。undefined symbol が出たら source tree を grep し、無ければ object の陳腐化。
- `build_config/esp32-stackchan.rb` に gem を足したら `r2p2:setup` が必要。`conf.gem` の gem は `build/repos/` に `--depth 1` で cache され、以後 pull されない。ずれは `tools/check_deps_pushed.sh` が検出し、戻れる形の commit 列 (`git branch keep-<sha>` → `fetch --depth 1` → `checkout --detach`) を出す。`rm -rf` は使わない — shallow clone なので消したら元の commit は戻らない。
- sdkconfig fragment を編集しても `idf.py build` は再適用しない。`ensure_sdkconfig_fresh` が rake 側で処理する。CoreS3 は `sdkconfigs/cores3` (Quad PSRAM)。BLE-only build は coex を全部 `n` にしないと `coex_schm_lock` で panic する。
- `idf.py flash` は storage 区画も焼くので `/home/app.mrb` が消える。flash 後は upload し直す。
- storage erase は `rake r2p2:wipe_storage` を通す (offset は partition table 依存、手打ちしない)。
- autostart 中の Ctrl-C で shell は戻らない。wipe で復旧する。
- 板は USB serial で選ぶ。CoreS3 の serial は gitignore された `.stackchan-usb-serial` (か `STACKCHAN_USB_SERIAL=`) に置き、port は rake ごとに `ioreg` で serial から引く (port を開かない)。ESP32-S3 は全部同じ製品名 `USB JTAG/serial debug unit` で列挙され、`usbmodemNNN` は差した口の locationID で決まるので、glob も製品名も port 名の保存も板を特定しない。ESP32-S3 が複数あって serial が無い時、serial が USB に無い時、`ESPPORT=` が serial の port と食い違う時、rake は推測せず止まる。reset 後に port が戻らなければ同じ serial を探し直し、別の板は採らない。`rake r2p2:boards` が serial と port の対応・CoreS3 の印・lock の持ち主を port を開かずに出す。
- serial を開く rake は R2P2-dev-harness と共通の `~/.cache/r2p2-device-locks/esp32.lock` を取る (同じ形式、持ち主の pid が死んでいれば奪う)。別 session が持っていれば待つ。acceptance は device を触る step ごとに取り、子の rake には `ESPPORT` と serial を env で明示的に渡す (`Bundler.with_unbundled_env` は起動時の環境に戻すので、後から `ENV` に入れた値は子に届かない)。
- boot log の capture (`r2p2:capture_resilient` / `reset_and_capture`、`bin/capture-with-pty`) は閉じる時に chip を ROM の download mode に残す。USB は列挙されたままで advertising だけが消える。capture の後に BLE を使うなら `r2p2:reset` を撃ち、起動 (約 15 秒で `HCI WORKING — advertising`) を待つ。acceptance の boot step はこれを自分で行う。
- serial port を触る rake は `ensure_no_concurrent_monitor` を呼ぶ。serial capture は `bin/capture-with-pty`、生 `cat` は禁止。
- boot 失敗は cold-boot 全体の log を取り `LoadError|cannot load|NameError|Guru Meditation` を最初の異常から読む。
- picoruby-uart: unit は `:ESP32_UART0..2`、`write` は String のみ、`read` は timeout を無視するので `readpartial` で poll。
- R2P2 の `$>` は POSIX 風 shell。Ruby 式は `irb` に入ってから。

## push guard hook

`.claude/settings.json` の PreToolUse hook が `tools/hooks/pre_push_guard.sh` を通して push を止める。実測した Claude Code の挙動:

- `matcher` は tool 名だけに当たる。`"Bash(git push*)"` は文字列 `Bash` に対する非 anchor の正規表現として評価され一致しない。command での絞り込みは handler 側の `"if"` フィールド (permission-rule 構文) だが、これは前方一致なので `git -C <dir> push` も `/opt/homebrew/bin/git push` も取りこぼす。取りこぼしが許されないなら `matcher: "Bash"` だけにして script 側で判定する。
- hook 設定の変更は session 再起動なしで次の tool call から有効。
- exit 2 で tool call が block される。**block 時に表示されるのは stderr だけ**で stdout は捨てられる。理由は stderr に書く。
- pin を公開する push は guard 自身に止められるので `STACKCHAN_DEPS_GUARD=off` を前置する。

## picoruby-ble の lineage を乗り換える時

個別 fix の cherry-pick ではなく gem 本体 (`mrblib/ src/ include/ sig/ mrbgem.rake` + `ports/esp32/{ble,ble_central,ble_peripheral,nimble_owner}.[ch]`) を丸ごと持ってくる。`mruby-task` の `mrb_task_queue_push` が要るので submodule `mruby/mruby` の sha を合わせる。`_event_popped` / `_event_queue_cleared` / `@event_queue` / `hci_power_control` の名前と可視性を grep で確認し、compile が通っても `ble_control_smoke` / `ble_servo_smoke` / `ble_torque_smoke` を実機で通すまで完了としない。

動作が確認できている組み合わせは `acceptance/lock.yml` の firmware pin。firmware 用の picoruby の線を upstream master に rebase したものは CoreS3 で起動しない。app を消しても `main_task: Returned from app_main()` の直後に `stack overflow in task picoruby_task` が出て boot loop に入る。`PICORB_TASK_STACK_SIZE` は両系統とも 8 KB なので、変わったのは startup 中の C stack 使用量。これを上げると 8 KB 前提の描画・BLE の制約ごと変わるので、tweak ではなく設計判断。値は R2P2-ESP32 の `components/picoruby-esp32/CMakeLists.txt` が環境変数 `PICORB_TASK_STACK_SIZE` から読むので fork の変更は要らないが、firmware が変わるので焼き直しと新しい acceptance report が要る (Rakefile からこの変数を渡す配線は未確認)。task stack は内部 RAM から取られ、mruby heap は PSRAM。QEMU の shell 時点で内部 RAM の空きは 271,703 B (最大連続 172,032 B) だが、NimBLE が起動した実機の値は測っていない。
