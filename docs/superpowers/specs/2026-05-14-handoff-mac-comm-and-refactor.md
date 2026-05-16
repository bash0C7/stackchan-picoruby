# Handoff: bring-up smoke 完了 → Mac 通信 (BLE / WiFi) + リファクタ

> 作成 2026-05-14。次セッション開始時に頭から読むこと。

## TL;DR

LED + face + heartbeat の cold-boot 3 点セットが CoreS3 実機で確認できた。次は BLE か WiFi で Mac との実通信を立ち上げ、その過程で全体設計を見直す。

## 現状 (2026-05-14 終了時点)

### 動いてるもの
- ILI9342 LCD で `Face::Neutral` 描画
- WS2812 12 個リングが boot 時に鮮赤点灯 (brightness 100)
- 10 秒 heartbeat 後 app.rb が exit して shell に戻る (`bring-up smoke v13`)
- PC 側 `pc/stackchan-protocol/exe/stackchan-control` CLI で frame 投げる
- PC 側 `pc/stackchan-protocol/exe/picomodem-upload` で /home/app.rb 上書き
- Rakefile の `r2p2:*` タスク群: `upload / build / build_flash / flash / reset / send_led / send_face / verify_led / capture / setup`

### 検証済み HW finding (= 必ず守ること)
- AXP2101 init は `0x90 = 0xBF` だけでは足りない。`0x97 / 0x69 / 0x30 / 0x90 / 0x94 / 0x95 / 0x27 / 0x99` 全部書く
- **AW9523 P0 (reg 0x02) = 0b00000111** が WS2812 5V rail enable。これを書かないと chip 側完璧でも暗黒
- PY32 GPIO 0 (VM_EN) HIGH + 200ms settle が必須
- PY32 GPIO 13 = WS2812 data line、push-pull 出力で初期化
- `refresh_leds` は read-modify-write 必須 (count を wipe しないため)
- ESP32-S3 native USB-CDC では `rake r2p2:reset` (RTS pulse) は chip reset しない。物理ボタン or 人間 monitor が確実

### 残ってる仮 / 未戻し
- `examples/app.rb` は **bring-up smoke** (loop なし、10s exit)。production の dispatcher loop は外したまま
- AW9523 + AXP2101 init は app.rb に直書き。driver 層に隠蔽してない
- frame protocol (Dispatcher / FrameParser) は upload との conflict 検証がまだ
- monitor を切らずに upload しようとすると port 競合する (memory 参照)

## Repo state

- **branch**: `feature/stackchan-display-bringup`
- **最新 3 commit** (`git log --oneline -3`):
  - `f50780e` chore(stackchan-protocol): bring-up smoke app.rb (v13-aw9523-p0)
  - `223c2e3` fix(py32-io-expander): RMW refresh_leds + add digital_write for VM_EN
  - `9cd5b99` feat(harness): vendor PicoModem uploader as versioned exe + r2p2 rake helpers
- **working tree**: clean

### 主要ディレクトリ
```
mrbgems/
  picoruby-py32-io-expander/     # PY32 chip driver (digital_write + RMW refresh)
  picoruby-stackchan-led/        # WS2812 driver on top of PY32 (brightness + animator)
  picoruby-stackchan-protocol/   # Frame parser + dispatcher + Face module + bring-up app.rb
pc/stackchan-protocol/
  exe/stackchan-control          # PC CLI (face/led/raw/combo)
  exe/picomodem-upload           # PicoModem ファイル uploader (Ruby + uart gem + handshake responder)
  lib/stackchan_protocol/        # FrameWriter, LedColorTable, etc.
docs/superpowers/specs/
  ↑ 過去 spec はここ。新 spec もここに追加
```

### Rakefile タスク早見表 (詳細は Rakefile 本体)
| Task | 内容 |
|---|---|
| `r2p2:setup` | host mruby から build。target 切替時のみ。10〜20 分 |
| `r2p2:rebuild_gems` | libmruby.a を消すだけ。次の build で gem の .rb 再生成 |
| `r2p2:build` | picoruby:build のみ |
| `r2p2:build_flash` | picoruby:build → flash 連結。基本フロー |
| `r2p2:flash` | flash のみ |
| `r2p2:reset` | RTS pulse (CoreS3 では chip reset 効かないこと注意) |
| `r2p2:upload` | `pc/stackchan-protocol/exe/picomodem-upload` 経由で SRC -> /home/app.rb |
| `r2p2:send_led` | COLOR=red MODE=solid 等で LED 制御 frame 投げる |
| `r2p2:send_face` | NAME=neutral 等で Face frame 投げる |
| `r2p2:verify_led` | reset + capture + send_led + tail log の one-shot |
| `r2p2:capture` | cat ESPPORT > log (run_in_background で起動推奨) |
| `r2p2:monitor` | idf.py monitor (人間用、claude code は TTY 無し) |

## 守るべきルール (memory に焼かれてる)

1. **rake task は subagent (haiku) で foreground 実行**。screen / longrun pattern 使わない
2. **subagent には rake 1 個 foreground のみ** 投げる。background process / 長 sleep / 複合 wait は main bash 側で
3. **Python 禁止**。`pc/stackchan-protocol/exe/picomodem-upload` (Ruby) を勝手に Python 化しない
4. **M5Stack ハード側 op は人間に振る**。物理 reset / USB 抜き挿し / monitor 経由 `rm /home/app.rb` 等は自動 recovery 粘らずお願い
5. **build / flash も longrun NG**。subagent 表起動で OK
6. **../StackChan は read-only**。reference として読むのみ
7. **PicoRuby 互換性**: `defined?` / `Hash#fetch` / inline rescue / proc / lambda 等は禁止 (確証は picoruby 本体 or chiebukuro-mcp で取る)
8. **upload で詰まった時の確実 recovery**: 人間に monitor 立ち上げ → `rm /home/app.rb` → Ctrl-] → main で `rake r2p2:upload`
9. **bring-up app は loop なし + 固定時間 sleep + exit**。これで上書き upload がスムーズに通る

memory 全 index は `~/.claude/projects/-Users-bash-dev-src-github-com-m5stack-stackchan-picoruby/memory/MEMORY.md` 参照。

## 次セッションで決めること

### Q1. BLE か WiFi か
- 現状はどちらも未実装
- USB-CDC 経由は uploader / debug 用に残す
- BLE: M5Stack StackChan 公式は BLE で通信してる (`hal_ble.cpp`)。低 latency、PC 側 RubyMotion / CoreBluetooth bridge 必要
- WiFi: ESP32-S3 で WiFi station + TCP/UDP/HTTP/WebSocket。Mac 側は普通の socket。シンプルだが latency 揺れる
- 用途: PC (rb-foundation-model-mac で Apple Foundation Model 経由) ↔ StackChan の avatar 通信。**latency より stability 優先**ならどちらも妥当
- PicoRuby on R2P2-ESP32 の BLE / WiFi gem の存在 / 成熟度 を最初に調べる必要あり (chiebukuro_query_ruby_knowledge / picoruby 本体 grep)

### Q2. 設計見直しの範囲
候補 (どれを今回スコープに入れるか議論):

A. **Board init を gem 化** (e.g. `picoruby-cores3-board` を新設)
   - app.rb から AXP2101 + AW9523 + ILI9342 + PY32 init を全部隠蔽
   - benefit: app.rb が用途ロジックだけになる
   - 副次: AW9523 P0 finding を gem にカプセル化、再発防止

B. **Bring-up app と production app の分離**
   - `examples/bringup_smoke.rb` (今の v13 相当) と `examples/avatar.rb` (dispatcher loop) を別ファイル化
   - autostart `/home/app.rb` をどっちにするかは状況で切り替え
   - bring-up smoke は uploader の race-free な test fixture として残せる

C. **Frame protocol に exit hatch 追加**
   - app.rb の dispatcher loop が STDIN 食って upload 詰まる問題の永続的解決
   - 候補: 特定 frame (例 `E\n`) で `exit`、または STX 検出で exit して shell に hand off
   - upload の前段に「exit 命令を投げて 1 秒待つ」を入れるパターン

D. **stackchan-led の brightness をハードな安全 cap に**
   - 今 100 まで上げられる。eye safety / 給電上限考慮で gem 内部に上限制御
   - bring-up smoke では cap を一時 override できる API も用意

E. **AW9523 P0 のどの bit が何を制御するか確定**
   - schematic 入手 or 一 bit ずつ実験で割り出し
   - WS2812 5V 専用 bit が分かれば最小限の bit だけ立てれば良い (今は 0b00000111 全部)

### 推奨スコープ
- B (bringup vs production 分離) と C (exit hatch) は upload sm のために優先
- A (board gem 化) は AW9523 P0 finding を gem に焼くついでに WiFi/BLE の前にやっとくと app.rb 側がスッキリする
- D / E は WiFi/BLE 後の polish で

## 物理セットアップ (人間にお願いする手順早見表)

| 状況 | アクション |
|---|---|
| Upload で `FILE_ACK got nil` 連続 | monitor 立ち上げ → `rm /home/app.rb` → `Ctrl-]` → claude 側で upload |
| board が silent (cat 0 byte) | 物理 reset ボタン押下 |
| USB device が消えた | USB 抜き挿し |
| storage を完全 wipe したい | BOOT 押しながら USB 挿し → download mode → claude 側で flash |
| boot ログを確実に見たい | 人間が `cd ../../bash0C7/R2P2-ESP32 && rake monitor` (別ターミナル) |

## 参考リンク

- StackChan 公式 firmware (read-only): `../StackChan/firmware/main/hal/`
- 本日の retrospective: https://bist.esa.io/posts/291 (試行錯誤の流れと決め手)
- bash さん自作 PicoRuby driver (構造参考): `~/dev/src/github.com/bash0C7/picoruby-mpu6886`, `~/dev/src/github.com/bash0C7/picoruby-vl53l0x`
- PC 側 AI: `~/dev/src/github.com/bash0C7/rb-foundation-model-mac`
- PicoRuby 本体: `~/dev/src/github.com/picoruby/picoruby`

## TODO (優先度順)

1. PicoRuby on R2P2-ESP32 の BLE / WiFi 対応 gem 棚卸し (chiebukuro + picoruby 本体探索)
2. BLE か WiFi の方向決め (Q1)
3. 設計見直しスコープ確定 (Q2 → 推奨は B + C 先行)
4. spec 書く (`docs/superpowers/specs/2026-05-XX-mac-comm-design.md`)
5. plan 書く (`docs/superpowers/plans/`)
6. 実装 → 実機検証 → commit
