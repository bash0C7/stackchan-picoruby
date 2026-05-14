# Handoff — stackchan-display bring-up (2026-05-14)

最後の動作確認：CoreS3 実機で 4 表情 (Neutral / Smile / Joy / Surprised) を 1500ms 間隔で自動サイクル。LCD 描画 OK・上品な公式比率・cold-boot OK。

## このセッションで進んだこと

1. **`rake r2p2:monitor` の port 食い違い**：`Rakefile` の `ESPPORT_DEFAULT='/dev/cu.usbmodem1101'` ハードコード → `/dev/cu.usbmodem*` glob 動的検出に
2. **cold-boot で LCD 真っ暗 → 解決**：原因は AXP2101 DLDO1 (LCD/backlight rail) が cold-boot で OFF、AW9523 P1.1 (LCD RST) も未制御。`mrbgems/picoruby-stackchan-protocol/examples/app.rb` 冒頭に I2C 経由の PMIC + IO Expander init を追加（詳細は memory `cores3-lcd-cold-boot-powerup`）
3. **face geometry を公式比率に**：image #11 (M5Stack 公式写真) から比率測定 → 目間隔 100px (0.31×W)、目 Y=100、口 Y=140、目→口 gap 40px (0.17×H)、目 radius 4、口 half-width 25
4. **`rake r2p2:rebuild_gems` task 追加**：mrblib/*.rb 中身変更時に必須。`libmruby.a` を消すだけ → 次回 `r2p2:build_flash` で picoruby rake 強制再起動 → bytecode .c 再生成 → libmruby.a 再構築。CMake の `add_custom_command(OUTPUT libmruby.a ...)` が source .rb の変更を追跡してへんから。memory `r2p2-setup-required-after-gem-change` 更新済
5. **Face::Surprised 追加**：縦長 filled rect 口 (12×24px) + 既存の目。protocol byte `"3"`、CLI `surprised`
6. **draw_mouth refactor**：`(display, delta_y)` → `(display)`、`self.class::DELTA_Y` 参照に。Surprised が独自実装で完全 override する設計
7. **app.rb を Dispatcher.run → autonomous cycling に**：4 表情を 1500ms 単位で循環。PC 制御は今は使ってへん

## 未コミットの変更（次セッションで判断要）

```
 M Rakefile                                                                # auto port + rebuild_gems
 M docs/STACKCHAN_PROTOCOL_VERIFICATION.md                                  # rebuild_gems 注記
 M mrbgems/picoruby-stackchan-protocol/examples/app.rb                      # cycling demo
 M mrbgems/picoruby-stackchan-protocol/mrblib/stackchan_protocol.rb         # 公式比率 + Surprised + refactor
 M mrbgems/picoruby-stackchan-protocol/test/fake_display.rb                 # draw_rect 追加
 M mrbgems/picoruby-stackchan-protocol/test/stackchan_protocol_test.rb      # 比率値 + Surprised テスト
 M pc/stackchan-protocol/lib/stackchan_protocol/cli.rb                      # help string 更新
 M pc/stackchan-protocol/lib/stackchan_protocol/face_table.rb               # surprised: "3"
?? mrbgems/picoruby-stackchan-protocol/vendor/                              # 前セッションから残ってる無視候補
```

- 1 〜数コミットに分けるか丸ごと feat コミットか相談
- `mrbgems/.../vendor/` は `.gitignore` 追加の方が綺麗（前セッションから surfaced 済）

## 次にやる候補

### 表情拡張続き（前回ユーザ希望順）

1. **にっこり顔**：目を弧 (∩) に、口を ∪ に。draw_arc ヘルパー追加 or 複数 line 近似。`Face::Happy` 等の新クラス
2. **目を動かす**：blink (点滅) or look (視線左右)。Dispatcher が blocking read やから、cycling demo に乗っかる形なら timer 駆動で簡単。PC 駆動なら non-blocking read への構造変更が要る

### 設計判断ペンディング

- **demo cycling vs PC 制御**：今 app.rb は cycling loop。`StackchanProtocol::Dispatcher` は使ってへん。両立させるなら：
  - 案 A: cycling 専用 demo モードと PC 制御モードを env var/flag で切替
  - 案 B: idle 時 cycling、PC byte 受信時はそっち優先（要 non-blocking STDIN）
  - 案 C: cycling 廃止して PC 制御に戻す
- **`tmp/picomodem_upload.rb` を昇格**：現状 `tmp/` (gitignore 対象) にあるから常用するなら `pc/stackchan-protocol/bin/picomodem-upload` 等に移動

### バックログ（前セッションから引き続き）

- `feature/stackchan-display-bringup` ブランチ fate 決め（merge / PR / keep）
- 2 commit のリモート push（要明示認可）：
  - `m5stack/stackchan-picoruby@047a150` (LCD power fix + doc)
  - `bash0C7/R2P2-ESP32@84fb1ae` (gemdir build fix)
- `docs/HARDWARE_VERIFICATION.md` の残タスク (IMU/Servo/Touch/LED driver 未着手)
- esa post #154 更新（hw verification outcome を section 追加）

## デプロイループ早見表

```bash
# mrblib の .rb 変えた時
rake r2p2:rebuild_gems r2p2:build_flash      # gem 再 mrbc + idf.py build flash (≈3-5 min)

# app.rb だけ変えた時（autostart 中だと upload 詰まる→先に flash で /home/ ワイプ）
rake r2p2:flash                              # storage 含めて再 flash → /home/ 空
sleep 10                                     # boot 完了待ち
cd pc/stackchan-protocol
bundle exec ruby ../../tmp/picomodem_upload.rb <abs/src/path> /home/app.rb
# 1 回目 FILE_ACK expected got nil でも、6 秒後リトライで通る
cd .. && rake r2p2:reset                     # autostart kick
```

PC client（cycling 中は無視されるけど、Dispatcher 復活時用）：

```bash
bundle exec ruby exe/stackchan-control --port /dev/cu.usbmodem101 surprised
# neutral / smile / joy / surprised / raw <byte>
```

## 関連 memory（次セッション自動 load）

- `cores3-lcd-cold-boot-powerup` — AXP2101+AW9523 init 必須
- `picomodem-upload-timing` — session TIMEOUT_MS=5000 待ち、autostart 中は不可
- `r2p2-setup-required-after-gem-change` — mrblib 変更時は rebuild_gems 必須
- `picoruby-require-name-convention` — hyphen 形

## 関連 spec / plan

- `docs/superpowers/specs/2026-05-14-stackchan-protocol-design.md`（§11 で R1〜R6 全部解決済み）
- `docs/STACKCHAN_PROTOCOL_VERIFICATION.md`（hw verification）
