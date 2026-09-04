# stackchan-picoruby

StackChan (M5Stack CoreS3 の StackChan AI デスクトップロボット) を PicoRuby / R2P2-ESP32 で動かす個人プロジェクト。
何ができるか・セットアップ・既知の問題は `README.md`、現在地は `HANDOFF.md`。このファイルは「この repo で作業する時の約束事」だけを書く。

## 作業の進め方

- 頼まれた範囲をそのまま作る。付随する refactor・抽象化・将来のための保険は足さない。動く最小の形でよい。
- 質問・相談・思考の吐き出しには判断を返して止まる。修正は頼まれてから。
- 進捗報告はツール結果に裏付けのあることだけ書く。未検証は未検証と言う。
- 実機・ビルド・deploy は `stackchan-device-*` skill 経由。`rake r2p2:*` を main context から直接叩かない。
- 長い rake (setup / build_flash / full_rebuild) は subagent (haiku) の foreground で 1 chain task として回し、log は `/tmp/stackchan-picoruby-debug/` に tee する。
- spec / plan / review / 調査レポートは Obsidian vault の `~/Library/Mobile Documents/iCloud~md~obsidian/Documents/ObsidianVault/02_dev_docs/stackchan-picoruby/{specs,plans,review}/` に置く。PR #427 関連は隣の `picoruby-ble-esp32-port/`。repo の `docs/` は commit する必要のあるものだけ。記事・WIP メモは esa (team `ksbrb`、カテゴリ `ｽﾀｯｸﾁｬﾝ`)。
- 日付・経緯・「以前は」を doc やコメントに残さない。現在の挙動を現在形で書く。経緯は git log に任せる。

## 検証と報告の規律

- **読んだ数値やファイルが、検証対象が生んだものか確かめる。** exit code を主張するなら pipe を外すか `set -o pipefail` / `${PIPESTATUS[0]}` を使う (`tee` は常に 0 を返す)。出力ファイルを読む前に mtime を見る。`cd` した後の相対パスは壊れると考える。stderr を捨てたまま成否を判定しない。subagent に走らせる時は「rake 本体の exit code を報告せよ」と prompt に書く。
- **完了を主張する前に、その機能が実際に使われる形で 1 回動かして出力を見る。** hook なら実 `git push` を撃つ。sha の到達性なら remote に問う。branch ref の存在確認・script の単体叩き・remote-tracking ref は代理であって本物ではない。実行できない経路は「未検証」と名指しする。
- **host で回帰検出できない箇所を「実機で確認する」に倒さない。** BLE 等の実体は薄い adapter に隔離してロジックを素の class に出し、無い harness / fake は新設する。実機のみで確認する範囲は adapter の数行に限定する。
- 指摘を 1 件受けたら、その 1 箇所を当てて終わりにしない。一般原因を 1 行で言語化し、目的から全体を導出し直す。

## PicoRuby らしさ

コードとファイル配置は [picoruby/picoruby](https://github.com/picoruby/picoruby) の mrbgems を手本にする。

- gem は `mrbgem.rake` + `mrblib/<gem>.rb` (+ `mrblib/<gem>/*.rb`) + `test/*_test.rb`。`mrblib` 内で sibling を `require` しない (build が全部 bundle する)。cross-gem の `require 'ble'` 等だけ書く。
- on-device の `require` 名は gem 名から `picoruby-` を落とした hyphen 形 (`require 'stackchan-protocol'`)。
- テストは picotest (`Picotest::Test` サブクラス、`test/*_test.rb`)。CRuby の test-unit は host-only ツール (`test-host/`) にだけ使う。
- 仕様が分からない時は `chiebukuro_query_ruby_knowledge` → 無ければ `vendor/R2P2-ESP32/components/picoruby-esp32/picoruby` を読む。「禁止メソッド」を推測で決めない。
- 複数 port を持つ gem (picoruby-ble の rp2040 と esp32 等) を触る時、従の port の仕事は `include/*.h` の契約に conform することだけ。ログ・説明コメント・観測性のような「一般に良いとされる」上乗せは、主の port に無ければ従にも置かない (既存分も消す)。契約自体の是非や主 port や共有層への論評は範囲外で、adversarial review がそこを叫んでも採らない。既存契約を従が自分の中で守れていない場合の是正は別で、これは必要。

### 実測で確認済みの CRuby との差

- `rescue` 節の裸の `raise` は元例外を再送出しない。`rescue Foo => e` … `raise e` と書く。
- mruby VM を回す FreeRTOS task の stack は 8 KB。C から block を yield する構文 (`Array.new(n) { }`、`String#dup` 等) は VM を 1 段ネストして約 3.1 KB 積む。描画・BLE の深い経路では `while` と C 実装メソッドで書く。症状は `stack overflow in task picoruby_task` の boot loop。host では再現しない。
- `String#[]=` のコストは差し込み先の全長に比例する。大きな buffer に行ごとに差し込まない。host では見えない。

## 構成

- Firmware (`build_flash` が必要): LCD / PY32 / servo / `StackchanProtocol::FrameParser` の gem。R2P2-ESP32 の build_config が GitHub から fetch する。
- Driver gems (`mrbgems/picoruby-*`): この repo 内の mrbgem。pure-Ruby の `stackchan-led` / `si12t` は Rakefile が `app.mrb` compile 時に application.rb の前に連結する。C を含む `aw88298` は firmware の build_config (`conf.gem github: 'bash0C7/stackchan-picoruby', path: 'mrbgems/picoruby-aw88298'`) に入れて `build_flash` する。C gem の形は upstream と同じ `src/<gem>.c` → `src/mruby/<gem>.c`。
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

SPI 転送は 1 回 4092 byte が上限。picoruby-spi の ESP32 port は bus を `max_transfer_sz`
未指定 + DMA 有効で作るので、esp_driver_spi が DMA descriptor 1 個分で頭打ちにする。超えると
`IOError: SPI write failed` になる。host の fake では再現しない。

## BLE プロトコル

- yaw: `<YL:0..100>` / `<YR:0..100>` (排他、YL 優先)、pitch: `<PU:0..100>` (上のみ)、timing: `<T:ms>` か `<V:speed>` のどちらか。
- 稀: `<torque:on|off>`、`<selftest:run>`、`<read:pos>` (`calibrate` だけが使う)。
- cold-boot は torque OFF + `Face::Closed`。操作者が正面に合わせて `<torque:on>`。
- 位置コマンドの detail `<YL_actual:N,PU_actual:N>` は **受信時点の姿勢** (移動後ではない)。`unknown` = キャリブレーション要。移動後の値が要るなら `<read:pos>` を使うか、次の位置コマンドの detail を読む。CLI の `raw` verb は device の detail を捨てて `OK raw` しか返さないので、`stackchan raw '<read:pos>'` では値が取れない。
- audio は半二重: `<A:N>` → device `<A:ready>` → `T = N*1000/8000 + 3000 ms` 静止 → RX queue drain → I2S 再生。PC は 1.5 s 待ってから blast、`N/8000 + 2 s` 待つ。
- CLI: `stackchan servo --yaw-left 50 --pitch-up 30 --time 500`、`stackchan torque on`、`stackchan calibrate --align-only`。face 名は `angry / closed / joy / neutral / sad / smile / surprised`。exit 6 = calibration needed、7 = verify fail。

### BLE 実装 notes

- heartbeat tick は約 1 秒。Mac の idle 切断は 15〜20 秒なので 10 秒以内に notify か write を流す。
- event drain は「`pop` の結果に関わらず毎 tick `_event_popped` を呼ぶ」。`BLE#start` は override しない。
- Mac scan で見えない時は先に `sudo pkill bluetoothd`。別 central で再現するかで環境要因を切り分ける。
- BLE 検証中に serial monitor を並走させない (port open の DTR/RTS で device が reset する)。
- Mac の BLE は `stackchan` CLI で自律実行する。人に iPhone を頼まない。CoreBluetooth は TCC 経由なので daemon は `rake pc:up` (launchd + `~/Applications/StackchanPico.app`) からしか動かない。`pc:vm_build` の後は `pc:app_bundle` を再実行。
- btstack/NimBLE thread と main task が同時に mruby heap を触ると crash する。device 側の cross-thread 対策は `picoruby-ble-bridge` gem。
- レイテンシは同一セッション内の 2 点でしか比較しない (セッション間で 15〜25% ぶれる)。描画コストは primitive 数に比例し、`SPI#write` 回数では説明できない。計測は `tools/latency_baseline.zsh` + `tools/latency_summary.rb`、face 別は `tools/face_profile.zsh`。

### launchd (`rake pc:up` / `lib/pc_lifecycle.rb`) の実測挙動

推測で書くと静かに壊れる。触る前にここを読む。

- `launchctl kickstart -k` は書き直した plist を読み直さない。launchd は bootstrap 時に定義を in-memory に取り込むので、設定を変えたら必ず `bootout` + `bootstrap`。kickstart 経路を残すと前日の設定で起動して成功と表示する。
- `bootout` は unload 完了前に返る。ポートが空くのと service 登録が消えるのは別のシグナルで、ポートは数ミリ秒で空くのに登録は残る。`launchctl print` が失敗する (= 不在) まで待ってから bootstrap する。
- **daemon のポートを接続で確認しない。** `wait_for_port` が connect して即 close すると、見捨てられた接続が drb ポートに残る。daemon は起動中 (sidecar priming) にブロックしており、協調 Task なのでそれを処理できず、後で相手のいないソケットへ書いて SIGPIPE で死ぬ。実測で bring-up 15 回中 4 回失敗、接続しない確認 (lsof) に変えて 15 回中 0 回。PicoRuby VM は SIGPIPE を trap できない (`Signal.list` に `PIPE` が無く、`Signal.trap` はどの形でも `SystemStackError`)。したがって「クライアントが切断すると daemon が死ぬ」性質自体は残っており、塞ぐには picoruby の socket 層で `SO_NOSIGPIPE` が要る。
- Ruby 4.0 は `drb` を default gem から外した。root の `Gemfile` に `gem 'drb'` が要る。host test は verifier を注入して本物の DRb 経路を通らないので、テストは緑のまま実機で LoadError になる。

## テスト

```
bundle exec rake test                 # picotest: device / pc / shared + 各 driver gem (host picoruby VM)
SUITE=pc FILTER=stackchan_central bundle exec rake test
bundle exec rake test:host            # CRuby-only tools (test-host/)
bundle exec rake picotest:build       # host VM 再 build (build_config/picoruby-test.rb、C gem 込み)。picoruby を更新した後に
```

- device suite は fakes (`test/fake_*.rb`) + stub (`test/picotest/stubs.rb`) + 抽出した application class + scservo source を VM に注入する (`test/picotest/harness.rb`)。C gem は host VM に compile されているので `require` で届く。
- pc suite は `ble_client.rb` / `cli_app.rb` / `daemon_app.rb` を同様に抽出し、`test/pc/stubs.rb` の stub と `test/pc/fake_radio.rb` で回す。`PICOTEST_VM=` で別 VM。
- pc suite は CRuby と host VM の両方で走る。host VM には実物の `Task` があり `DRb` は無い。`Task` を stub するなら `unless Object.const_defined?(:Task)` で囲む。host VM の Task は picotest が yield しない限り body を走らせないので、両方で同じ観測になる。
- face geometry golden は `spec/golden/face_<name>.dump`。更新は `rake face:register_golden FACE=<name>`。
- picoruby-scservo は firmware build が fetch する。build 前は `SCSERVO_RB=` で clone を指す。
- host VM は `build/host-picotest` に建つ。R2P2-ESP32 自身の host ツールは `build/host` なので衝突しない。全 suite が `uninitialized constant Picotest` になったら、順序ではなく build 名の衝突を疑う。

## ビルド・deploy

| 用途 | 手段 |
|---|---|
| app だけ変えた | `/stackchan-device-iterate` (picomodem upload、flash に優しい) |
| firmware / gem / sdkconfig を変えた | `/stackchan-device-build-flash` → `/stackchan-device-cold-recovery`、または `/stackchan-device-full-rebuild` |
| 初回・target 切替 | `/stackchan-device-setup` |
| 復旧 | cold-recovery → full-rebuild → 人手 (USB 抜き差し / download mode) |

- `.rb` の直接 upload は禁止。必ず host で picorbc compile した `.mrb` を上げる (on-device compile は codegen stack overflow)。
- `main_task.rb` は `/home/app.mrb` を無条件に `load` し、このアプリは戻らないので `$shell.start` に到達しない。抜ける keypress も無い。`upload_appmrb` はこのため先に `wipe_storage` を通す。`upload_mrb` (`DST=`) は app.mrb を壊さずに wipe できないので、autostart 中の device への helper upload は wipe → helper → app.mrb の順になる。
- device 側に一時的な `puts` を足さない。cold boot で Guru Meditation の boot loop に入ることがあり (原因未特定、`Loading app.mrb` 直後で panic)、そうなると USB CDC が再列挙し続けて esptool も繋がらない。復旧は人間による USB 抜き差しだけで、抜き差し直後の 1 回しか esptool が通らないので、その 1 回を何に使うか決めてから頼む。
- smoke や upload の前に boot log で device の素性を確かめる。`boot: Partition Table:` の storage offset が `0x410000` か、`App version` がこの repo の build か、`[application] boot` / `[boot] step:` marker があるか。違えば別 tree の firmware なので `/stackchan-device-full-rebuild`。実機への上書き deploy は承認済み。
- firmware build は必ず clean build (`clean_picoruby_build` 依存を外さない)。undefined symbol が出たら source tree を grep し、無ければ object の陳腐化。
- `build_config/xtensa-esp-picoruby.rb` に gem を足したら `r2p2:setup` が必要。`conf.gem` の gem は `build/repos/` に `--depth 1` で cache され、以後 pull されない。ずれは `tools/check_deps_pushed.sh` が検出し、戻れる形の commit 列 (`git branch keep-<sha>` → `fetch --depth 1` → `checkout --detach`) を出す。`rm -rf` は使わない — shallow clone なので消したら元の commit は戻らない。
- sdkconfig fragment を編集しても `idf.py build` は再適用しない。`ensure_sdkconfig_fresh` が rake 側で処理する。CoreS3 は `sdkconfigs/cores3` (Quad PSRAM)。BLE-only build は coex を全部 `n` にしないと `coex_schm_lock` で panic する。
- `idf.py flash` は storage 区画も焼くので `/home/app.mrb` が消える。flash 後は upload し直す。
- storage erase は `rake r2p2:wipe_storage` を通す (offset は partition table 依存、手打ちしない)。
- autostart 中の Ctrl-C で shell は戻らない。wipe で復旧する。
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

動作が確認できている組み合わせは R2P2-ESP32 `c-primitives-verified` (`2f18720`) + picoruby `7258676d`。upstream master に rebase した lineage (picoruby `568b4b88`、R2P2-ESP32 `stackchan-integration`) は CoreS3 で起動しない。app を消しても `main_task: Returned from app_main()` の直後に `stack overflow in task picoruby_task` が出て boot loop に入る。`PICORB_TASK_STACK_SIZE` は両系統とも 8 KB なので、変わったのは startup 中の C stack 使用量。これを上げると 8 KB 前提の描画・BLE の制約ごと変わるので、tweak ではなく設計判断。
