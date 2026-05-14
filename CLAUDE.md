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

## CoreS3 cold-boot 初期化シーケンス (bring-up finding)

**LCD と WS2812 を cold-boot で確実に出すには、ESP32 SoC の SPI/GPIO init だけでは不足。** 必ず system I2C bus (SDA=GPIO 12 / SCL=GPIO 11) で以下を順に叩く:

1. **AXP2101 PMIC @ 0x34** — `0x97 / 0x69 / 0x30 / 0x90 / 0x94 / 0x95 / 0x27 / 0x99` を全部書く。`0x90 = 0xBF` (LDO 一括 ON) だけでは LCD バックライトと一部 rail が立たない。Reg 0x99 が DLDO1 voltage = LCD/backlight rail
2. **AW9523 IO Expander @ 0x58** —
   - `Reg 0x02 (P0 output) = 0b00000111` で **WS2812 用 5V rail を enable**。これを書かないと PY32/WS2812 chip 側を完璧に叩いても暗黒のまま (2026-05-14 検証で発見)
   - `Reg 0x03 (P1) 0x81 → 20ms → 0x83` で P1.1 を pulse、これが LCD reset
   - 書き順は reference (`../StackChan/firmware/main/hal/board/stackchan.cc:148-156`): P0 output → P1 output → CONFIG_P0 → CONFIG_P1 → GCR → LEDMODE_P0 → LEDMODE_P1
3. **PY32 IO Expander** — GPIO 0 (VM_EN) HIGH + 200ms settle、GPIO 13 (WS2812 data line) を push-pull 出力で初期化、`refresh_leds` は read-modify-write 必須 (count を wipe しない)
4. **ILI9342 driver の `rst_pin` / `bl_pin`** — AW9523 / AXP2101 経由なのでダミー GPIO (例 GPIO 1 等の未配線) を渡す

実装例: `mrbgems/picoruby-stackchan-protocol/examples/app.rb` 冒頭ブロック (= bring-up smoke v13)。将来 `picoruby-cores3-board` 的な gem に隠蔽する場合は **必ず AW9523 reg 0x02 = 0b00000111 を含めること**。

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

### PicoModem upload timing

- **upload リトライは 6 秒以上待ってから**。直前の probe / 失敗 upload で device 側 `read_exact` の TIMEOUT_MS=5000ms 経過待ちが入る
- `rake r2p2:flash` 直後は **8〜12 秒待って boot 完了させる**
- 「shell 生きてるか確認」は STX 単発送信 → 1 秒以内に `\n^B\n\x06` 来れば OK (ただし後で 6 秒待つ)
- autostart が走ってる時は PicoModem 不可。recovery は **人間に monitor 立ち上げてもらって `rm /home/app.rb` → `Ctrl-]`** が確実 (下記 HW op ルール参照)
- **uploader (`pc/stackchan-protocol/exe/picomodem-upload`) は Ruby + uart gem の自前実装**。Python に書き直さない (global の No Python ルール準拠)

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
- SDKCONFIG_DEFAULTS の組み立て：`sdkconfig.defaults;sdkconfigs/usb_console;sdkconfigs/cores3`（Rakefile にハードコード済み）

### 物理 / shell-level op は人間に振る (recovery を粘らない)

claude 側で rake task を組み合わせて自動 recovery を粘るより、**最初から人間に振る**。1 セッションで自動 recovery を 3-4 周回した結果、ESP32-S3 native USB-CDC の特性 (RTS pulse で chip reset しない、autostart 中の STDIN 占有、cat の re-enumerate EOF) で詰まることがほぼ確定:

| 状況 | 人間に振るアクション |
|---|---|
| Upload で `FILE_ACK got nil` 連続 | monitor 立ち上げ → R2P2 shell prompt まで待つ → `rm /home/app.rb` → `Ctrl-]` で抜ける → claude 側で `rake r2p2:upload` |
| board が silent (cat 0 byte) / boot ログを確実に見たい | 人間が別ターミナルで `cd ../../bash0C7/R2P2-ESP32 && rake monitor` (Ctrl-] 抜け含む) |
| USB device が消えた | USB 抜き挿し |
| storage を完全 wipe したい | BOOT 押しながら USB 挿し → download mode 強制 → claude 側で flash |
| 板の物理状態 (LED 光ってる？画面に何が出てる？) | 目視確認をお願い (serial trace は補助) |

- claude code の Bash は TTY が無いから `idf.py monitor` / `rake monitor` は使用不可 (即詰む)
- 軽量に boot ログ確認したい場合のみ：`cat /dev/cu.usbmodem1101 > tmp/longrun/serial.log` を `run_in_background` で起動 → `rake r2p2:reset` → log を Read。ただし USB-CDC re-enumerate で EOF するリスクあり、確実性は monitor 経由 < 人間視認

### R2P2 shell REPL は二段構成

CoreS3 起動直後に出る `$>` は POSIX 風 shell プロンプトで Ruby 式は通らない (`p Foo` は command not found)。Ruby 評価は `irb` コマンドで REPL に入って `irb>` プロンプトに切り替えてから。動作確認スクリプトを送るときは必ず `irb` 経由で。

### ロングバッチ (rake は適用外)

`r2p2:setup` (10〜20 分) や `r2p2:build_flash` (5〜10 分) は `~/dev/src/CLAUDE.md` の 2 分超ロングバッチ規約に通常該当するが、**本プロジェクトでは上記「rake は subagent foreground で 1 個ずつ」が override する**。screen -dmS は使わず subagent (haiku) 表起動で大きい timeout (600000ms+) を設定。

rake 以外の長時間 batch job (大量 LLM ループ、SDK ingest 等) には引き続き `~/dev/src/CLAUDE.md` の `screen -dmS` + `DONE:` sentinel pattern が適用される。
