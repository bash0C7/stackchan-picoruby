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
  - `/Users/bash/dev/src/github.com/bash0C7/picoruby-mpu6886`（IMU、構造が近い）
  - `/Users/bash/dev/src/github.com/bash0C7/picoruby-vl53l0x`
- PC側AI: `/Users/bash/dev/src/github.com/bash0C7/rb-foundation-model-mac`（Apple Foundation Model のRubyバインディング）
- PicoRuby本体（仕様確認用）: `/Users/bash/dev/src/github.com/picoruby/picoruby`

## アーキテクチャ方針

PC連携アバターパターン：

- **StackChan側**：R2P2-ESP32 + PicoRuby スクリプト。I/O 端末として動作。センサ値を読んでシリアルで送信、PCからのコマンドでサーボ/LED/表情を駆動
- **PC側**：Ruby (rb-foundation-model-mac) でローカルAI判断。**Mac との通信は WiFi (picoruby-esp32 + picoruby-socket + picoruby-net-http/-mqtt/-websocket) を本命**。R2P2-ESP32 は sdkconfig で `CONFIG_ESP_WIFI_ENABLED=y` 既に有効、SSLSocket も mbedTLS で完成。BLE は `picoruby-ble` の ESP32 port (BTstack binding) が未成熟なため当面 deferred。USB-serial は uploader / debug 用途で残す

### Firmware vs application boundary

- Firmware (mrbgems, requires `build_flash`): hardware drivers + stable
  protocol framework (`StackchanProtocol::FrameParser` only).
- Application (`mrbgems/picoruby-stackchan-protocol/examples/application.rb`,
  deploy via `upload_appmrb`): all StackChan business logic — `Face` DSL,
  `Dispatcher`, BLE peripheral, cold-boot init.
- Host tests load application class definitions via prism AST through
  `lib/ruby_class_extract.rb`. Application code must keep class
  definitions free of `< BLE` patterns at the class-body top level so the
  exclusion filter can skip them cleanly.

## CoreS3 cold-boot 初期化シーケンス (bring-up finding)

**LCD と WS2812 を cold-boot で確実に出すには、ESP32 SoC の SPI/GPIO init だけでは不足。** 必ず system I2C bus (SDA=GPIO 12 / SCL=GPIO 11) で以下を順に叩く:

1. **AXP2101 PMIC @ 0x34** — `0x97 / 0x69 / 0x30 / 0x90 / 0x94 / 0x95 / 0x27 / 0x99` を全部書く。`0x90 = 0xBF` (LDO 一括 ON) だけでは LCD バックライトと一部 rail が立たない。Reg 0x99 が DLDO1 voltage = LCD/backlight rail
2. **AW9523 IO Expander @ 0x58** —
   - `Reg 0x02 (P0 output) = 0b00000111` で **WS2812 用 5V rail を enable**。これを書かないと PY32/WS2812 chip 側を完璧に叩いても暗黒のまま (2026-05-14 検証で発見)
   - `Reg 0x03 (P1) 0x81 → 20ms → 0x83` で P1.1 を pulse、これが LCD reset
   - 書き順は reference (`../StackChan/firmware/main/hal/board/stackchan.cc:148-156`): P0 output → P1 output → CONFIG_P0 → CONFIG_P1 → GCR → LEDMODE_P0 → LEDMODE_P1
3. **PY32 IO Expander** — GPIO 0 (VM_EN) HIGH + 200ms settle、GPIO 13 (WS2812 data line) を push-pull 出力で初期化、`refresh_leds` は read-modify-write 必須 (count を wipe しない)
4. **ILI9342 driver の `rst_pin` / `bl_pin`** — AW9523 / AXP2101 経由なのでダミー GPIO (例 GPIO 1 等の未配線) を渡す
5. **BLE を続けるなら cold-boot 完了後に `sleep_ms 3000` で必ず yield する** (2026-05-17 bisect 確定)。cold-boot 全体 (特に Face::Neutral.draw の 150KB pixel push) は同期 SPI/I2C で CPU を占有し、BTstack の FreeRTOS task が初期化を完走できない。yield せず `BLE.new` → `start` に入ると `gap_advertisements_enable(1)` は呼ばれても **RF emit が silent fail** する (device-side log には `HCI WORKING — advertising` が出る、Mac scan / iPhone nRF Connect では一切見えない)。最小値は未測定で 3000ms は安全策

実装例: `mrbgems/picoruby-stackchan-protocol/examples/app.rb` 冒頭ブロック (= bring-up smoke v13)、`mrbgems/picoruby-stackchan-protocol/examples/application.rb` (cold-boot 後 sleep_ms 3000 入り)。将来 `picoruby-cores3-board` 的な gem に隠蔽する場合は **必ず AW9523 reg 0x02 = 0b00000111 を含めること**、それと **BLE と組合せる場合の yield 必要性をドキュメント明記すること**。

## PicoRubyの制約・互換性の調べ方

固定リストに頼らない。以下の順で確認する。

1. `chiebukuro-mcp` の Ruby/PicoRuby ナレッジDB (`chiebukuro_query_ruby_knowledge` / `chiebukuro_semantic_search_ruby_knowledge`)
2. 答えが無い・根拠が必要なら `/Users/bash/dev/src/github.com/picoruby/picoruby` を Explore subagent で調査
3. 仕様確認できないまま「禁止メソッド」前提で書かない

## 開発ルール

- ドライバー開発は基本 https://picoruby.org/terminal で実装・実機検証
- C拡張のmrbgemsが必要な場合のみ R2P2-ESP32 のビルドツリーに組み込む
- PicoRubyドライバーの構成は picoruby-mpu6886 / picoruby-vl53l0x のレイアウトを踏襲
- 公式 `../StackChan` には書き込まない。ピン配置や初期化シーケンスは読み取って参考にするだけ
- spec / plan は `docs/superpowers/specs/` `docs/superpowers/plans/` に置く

### mrbgem pitfall (実機で詰まりがち)

- **on-device の `require` 名は gem 名から `picoruby-` を strip した hyphen 形**。`picoruby-stackchan-protocol` → `require 'stackchan-protocol'` (underscore で書くと `LoadError`)。host テスト (CRuby + Bundler) は `$LOAD_PATH` で underscore でも解決するから on-device だけが prebuilt list (`mrbgems/picogem_init.c`) に依存
- **`build_config/xtensa-esp-picoruby.rb` に新 gem 行追加 → `rake r2p2:setup` 必須**。`rake r2p2:build_flash` 単独では `gem_init.c` / `picogem_init.c` が再生成されず新 gem が含まれない
- **既存 gem の `mrblib/*.rb` 内容を変えただけなら軽量修復ルート**: `cd $R2P2/components/picoruby-esp32/picoruby && MRUBY_CONFIG=$R2P2/components/picoruby-esp32/build_config/xtensa-esp-picoruby.rb rake` → `idf.py build flash`。重い `r2p2:setup` フル不要
- **`conf.gem` 表記は `gemdir:` のみ**。`path:` は picoruby の `MRuby::LoadGems` に拒否される

### bring-up app の書き方 (upload race-free)

- **bring-up app.rb は `loop` を持たず、固定時間 sleep + exit にする**。dispatcher loop が STDIN を独占すると uploader の STX が face byte として消費され、PicoModem session が立たず upload 詰まる
- `examples/app.rb` (現状の bring-up smoke v13) は 10 秒 heartbeat 後に exit して shell に戻る形で、上書き upload がスムーズに通る
- production 用の dispatcher loop を入れる場合は **「特定 frame (例 `E\n`) で exit」または「STX 検出で shell に hand-off」の exit hatch を frame protocol に組み込む** ことを前提にする (Q2-C リファクタ項目)

### rake は subagent foreground で 1 個ずつ

- **本プロジェクトの rake task は全て subagent (general-purpose, model: haiku) 経由で foreground 起動**。screen `-dmS` longrun pattern は build / flash / upload / test いずれも使わない (`~/dev/src/CLAUDE.md` の 2 分超ロングバッチ規約に対する **本プロジェクト局所の override**)
- subagent には rake を **1 個 foreground 実行するだけ** 投げる。background process / 長 sleep / 複合 wait は main の Bash で組み立てる (例「reset しつつ boot log 取る」は ① main で `cat > log &` ② subagent で `rake r2p2:reset` ③ main で `sleep 12 && kill` ④ main で log read)
- 結果要約 + pass/fail 報告は haiku に任せ、失敗の深掘り・design 判断は main (opus) が memory + spec から組む
- 例外は `r2p2:setup` (host mruby 一から組む 10〜20 分): 通常 subagent (haiku) で大きい timeout (600000ms+) で foreground 実行

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
| edit + host test | `bundle exec rake test` |
| device iterate | `/stackchan-device-iterate` |
| HITL face check | `/stackchan-device-face-verify FACE=...` |

Recovery escalation (escalate after 2 tries):

1. `/stackchan-device-cold-recovery`
2. `/stackchan-device-full-rebuild`
3. Human-driven recovery (USB replug, monitor manual, download mode)

## R2P2-ESP32 ビルド・flash フロー（CoreS3 ターゲット）

stackchan-picoruby 直下の `Rakefile` に `r2p2:*` タスク群を集約。隣リポジトリ `../../bash0C7/R2P2-ESP32` への呼び出しと esp-idf env source を全部ラップ済み。

| タスク | 用途 |
|---|---|
| `rake r2p2:build_flash` | **基本フロー**。`picoruby:build → flash` を 1 screen 内で連結。build 失敗時は rake が flash を自動 skip。build と flash を別 kick する流れは禁止 |
| `rake r2p2:setup` | 初回・target 切り替え後。`setup_esp32s3` = deep_clean + mruby host rebuild + `idf.py set-target esp32s3`。`idf.py fullclean` のみだと target が default `esp32` に戻り IRAM overflow でリンク失敗する |
| `rake r2p2:reset` | RTS pulse で CoreS3 再起動。serial キャプチャ前に呼ぶ |
| `rake r2p2:flash` / `rake r2p2:build` | 個別 fallback。普段使わない |

### CoreS3 固有の sdkconfig

- `bash0C7/R2P2-ESP32/sdkconfigs/cores3`：`SPIRAM=y` + `SPIRAM_MODE_QUAD=y` + `SPIRAM_SPEED_80M=y`。CoreS3 は **Quad PSRAM 8MB**（Octal でない）。デフォルトの `sdkconfigs/spiram` は `MODE_OCT=y` なので CoreS3 で使うと PSRAM ID 読み失敗 → boot loop
- `bash0C7/R2P2-ESP32/sdkconfig.defaults`：`CONFIG_ESPTOOLPY_FLASHSIZE_16MB=y`（CoreS3 は 16MB Flash）
- SDKCONFIG_DEFAULTS の組み立て：`sdkconfig.defaults;sdkconfigs/usb_console;sdkconfigs/cores3;sdkconfigs/bt_btstack`（Rakefile にハードコード済み）

### sdkconfig fragment 編集後は自動再生成 (2026-05-15 finding)

`idf.py build` は **既に存在する sdkconfig に SDKCONFIG_DEFAULTS を再適用しない**。fragment を編集しても次回 build に反映されないので silent regression に詰む。

対策: stackchan-picoruby `Rakefile` の `r2p2:build` / `r2p2:build_flash` は **`ensure_sdkconfig_fresh`** を先に走らせて、いずれかの fragment が `sdkconfig` より新しい場合は `sdkconfig` を rm → 次の idf.py build で再生成される。手動で `rm sdkconfig` する必要は無い。

### BLE on CoreS3: COEX 完全 disable 必須 (2026-05-15 finding)

BLE-only build (BTstack vendored、WiFi 並走無し) で `CONFIG_SW_COEXIST_ENABLE=y` のままだと、BT controller の内部 task `btdm_controller_on_reset` → `bt_rf_coex_hook_st_set` → `coex_schm_status_bit_clear` → **ROM `coex_schm_lock`** で **uninitialized semaphore handle (`0x82xxxxxx` 等の高 bit set) を semphr_take して LoadProhibited panic**。

ROM 側の `coex_schm_env` 参照経路が IDF v5.4 + ESP32-S3 + BLE-only で破綻している (詳細は addr2line + 一行 disasm で確認済)。`sdkconfigs/bt_btstack` で **全 coex 関連 flag を `n`** に：

```
CONFIG_SW_COEXIST_ENABLE=n
CONFIG_ESP_COEX_SW_COEXIST_ENABLE=n
CONFIG_ESP_COEX_ENABLED=n
```

これで `bt.c` 内 `coex_schm_status_bit_clear_wrapper` 等が `#if CONFIG_SW_COEXIST_ENABLE` ガードで no-op になり、BT controller の coex hook も harmless 化、ROM 経路に到達しない。WiFi 起動時に coex 必要になったら戻す (この時は `coex_schm_init` が正しく走るか別 issue として再評価)。

### BTstack は thread-safe ではない (2026-05-15 finding)

BTstack vendored ESP32 port の README 明記：
> BTstack is not thread-safe... To call a function from the BTstack thread, you can use *btstack_run_loop_execute_on_main_thread*

picoruby-ble の `BLE_init` / `BLE_hci_power_control` / `BLE_peripheral_advertise` 等は Ruby thread から呼ばれるが BTstack 内部は run_loop_freertos thread。**全部 btstack thread で実行** させる必要がある：

- `ports/esp32/btstack_owner.c` に `picoruby_btstack_ensure_started(setup_cb, ctx)` + `picoruby_btstack_run_sync(cb, ctx)` API を追加
- `BLE_init` の `l2cap_init / sm_init / att_server_init / hci_add_event_handler` 一式は setup callback として btstack_task 内 (run_loop_execute 前) で実行
- 起動後の runtime call (`hci_power_control` / `gap_advertisements_*` 等) は `btstack_run_loop_execute_on_main_thread` 経由で semaphore 同期 dispatch
- 同じ btstack thread から呼ばれた場合は dispatch せず直接 call (short-circuit) — deadlock 回避

### Storage 区画は `idf.py flash` で wipe される

`idf.py flash` は build/storage.bin も含めて 4 partition 全部書き込む → **`/home/app.rb` は build_flash 毎に消える**。flash 後は必ず `rake r2p2:upload SRC=...` で再 upload してから `rake r2p2:reset`。

### Recovery

See `stackchan-device-cold-recovery` / `-full-rebuild` skills and the
README recovery section. Memory entries describing the old wipe → flash
hierarchy are obsolete; the skills encode the same logic and supersede
them.

### R2P2 shell REPL は二段構成

CoreS3 起動直後に出る `$>` は POSIX 風 shell プロンプトで Ruby 式は通らない (`p Foo` は command not found)。Ruby 評価は `irb` コマンドで REPL に入って `irb>` プロンプトに切り替えてから。動作確認スクリプトを送るときは必ず `irb` 経由で。

### ロングバッチ (rake は適用外)

`r2p2:setup` (10〜20 分) や `r2p2:build_flash` (5〜10 分) は `~/dev/src/CLAUDE.md` の 2 分超ロングバッチ規約に通常該当するが、**本プロジェクトでは上記「rake は subagent foreground で 1 個ずつ」が override する**。screen -dmS は使わず subagent (haiku) 表起動で大きい timeout (600000ms+) を設定。

rake 以外の長時間 batch job (大量 LLM ループ、SDK ingest 等) には引き続き `~/dev/src/CLAUDE.md` の `screen -dmS` + `DONE:` sentinel pattern が適用される。
