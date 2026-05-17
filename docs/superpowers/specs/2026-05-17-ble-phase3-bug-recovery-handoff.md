# BLE Phase 3 — Bug Recovery Handoff (2026-05-17 夜)

このファイルは **2026-05-17 day session の途中での失策を引き継ぐ** ためのリカバリ handoff。前 handoff (`2026-05-17-ble-phase3-execution-handoff.md`) は §5 で `peri.start(0)` で無限 advertise と仮定したが、これが **0ms run** と解釈されて即終了する仕様で、application.rb が shell に落ちる crash-loop 風挙動を起こした。この session で `peri.start(60_000)` (Phase 2 実証値) に修正し、boot.log で device 側 run loop の発火確認まで到達。**Mac scan / E2E 検証は持ち越し**。

---

## 0. 起動コピペ用 prompt

```
stackchan-picoruby BLE Phase 3 のバグ復旧後の続きや。

まず docs/superpowers/specs/2026-05-17-ble-phase3-bug-recovery-handoff.md を読んで、その指示通りに進めて。
前 handoff (2026-05-17-ble-phase3-execution-handoff.md) は Draft assumption #2 が外して
ハマったので、こちらの bug-recovery 版を優先。
```

---

## 1. この handoff の存在意義 (=直前 session の失策サマリ)

### 失策 1: handoff の "Draft assumption" を検証せず実装に書き込んだ

前 handoff `2026-05-17-ble-phase3-execution-handoff.md` §5 表 #2:

> | 2 | `peri.start(0)` で無限 advertise | Task 18 Step 1 | `0xFFFFFFFF` 等 large value に置換、`application.rb` 末尾を編集 |

これを「実装には書いていい、後で検証」と解釈して Task 15 で `peri.start(0)` を application.rb に commit (`96302fe`)。

実機で動かしてみたら `peri.start(0)` は picoruby-ble が「0ms run, return」と解釈する仕様 (実機ログ: `Starting for 0 ms` → `Stopped`)。`start` の返り値の後に `puts "should not reach here"` が出て R2P2 shell が STDIN を握り、device は crash-loop 風挙動。user が手動で `rm /home/app.mrb` → reboot で recovery。

**教訓** (memory `feedback_verify_handoff_assumptions_first.md` に保存):
- handoff doc の Draft assumption / TBD / 未検証 と書かれた仮定は **critical path に影響するなら最初に検証 task を組む**
- 実証されてない大きい値 (`0xFFFFFFFF` 等) も **同じ罠**
- Phase 2 実証値 (`60_000`) のみが「使っていい引数」、それ以外は推測

### 失策 2: claude code 自身でできる BLE scan を人間に外注

advertise の確認のため「iPhone nRF Connect で scan して」と user に依頼。実際は `rb-corebluetooth-mac` gem 経由で claude code の Bash から Mac BLE scan できる。

**教訓** (memory `feedback_claude_can_do_mac_ble_scan.md` に保存):
- Mac scan / connect / NUS write / ACK 受信 は claude code 自身で
- 人間に振るのは **物理的視認 (LED / LCD)、USB 抜き挿し、BOOT ボタン** だけ

### 失策 3: 単純な closed-question に対し option を捏ね回した

「peri.start の引数どう直す？」に対し (a) loop wrap / (b) 0xFFFFFFFF / (c) smoke 用 60s と 3 択を提示。証拠は Phase 2 の `start(60_000)` のみ。closed-question で「`60_000` を 1 回呼ぶ」だけが evidence-based 唯一解だった。

**教訓**: 動いた実証コードがある時、それ以外は推測。option を作る前に「実証だけから答え出るか？」確認する。

### 失策 4: scope 外の変更を混ぜようとした

user 指示「これ以外の変更をいれるな」に対し、debug puts のつもりで `@hb_tick = 0` (instance state) を追加。puts 以外の変更は脈絡なし。即 revert。

**教訓**: 「debug puts」と指示されたら **puts だけ**。state 追加 / 既存ロジック改変は許可外。

---

## 2. 現セッション末の verified state

### Repo / Branch

| 項目 | 値 |
|---|---|
| Branch | `feature/ble-phase3-control` |
| HEAD | `23da674` (`fix(application): peri.start(0) → peri.start(60_000)`) |
| origin/main からの差 | 18 commits ahead, push 未 |
| working tree | (この handoff commit 前で) clean |

### application.rb (`mrbgems/picoruby-stackchan-protocol/examples/application.rb`)

末尾:

```ruby
# [4] Run BTstack run_loop for 60_000ms. Phase 2 ble_smoke.rb で実証済みの引数で、
# 60s 経過後に start() は return する仕様 (引数は ms)。Phase 3 production として
# 常時 advertise したい場合の loop 化や別 N 値は未検証なので別件。60s 経過後は
# このスクリプトが終了し、R2P2 shell に制御が戻る (Phase 2 と同じ挙動)。
puts "[application] BLE peripheral starting (60s)"
peri = StackChanApp.new(display: display, led: led)
peri.debug = true
peri.start(60_000)
puts "[application] start returned (60s elapsed)"
```

debug puts も追加済み:
- `[application] initialize: super(:peripheral) entering` / `super returned`
- `[application] pkt evt=<byte>` (packet_callback 冒頭)
- `[application] heartbeat` (heartbeat_callback 冒頭)

### Hardware verified facts (`/tmp/boot.log`)

device-side で確認できた到達範囲:

1. ✓ `[application] boot` — autostart で app.mrb 起動
2. ✓ `[application] PY32 REG_VERSION = 0x41` — I2C 通信生きてる
3. ✓ `[application] LCD + LED cold-boot done` — AXP/AW/SPI/ILI/PY32/LED 全部 init OK
4. ✓ `[application] BLE peripheral starting (60s)`
5. ✓ `[application] initialize: super(:peripheral) entering`
6. ✓ picoruby-ble btstack_task starting / att_db / att_server_init / BLE_INIT / BTstack ready
7. ✓ `BTstack up and running at 44:1B:F6:E2:05:66`
8. ✓ `[application] initialize: super returned`
9. ✓ **`Starting for 60000 ms`** ← picoruby-ble 自身が ms 単位の引数を echo
10. ✓ `[application] pkt evt=96` — packet_callback 発火、event=0x60 (BTSTACK_EVENT_STATE)
11. ✓ `[application] HCI WORKING — advertising` — `advertise(@adv_data)` 到達
12. ✓ `[application] heartbeat` × 7 (~1s/tick で run loop 生きてる)

### 重要な未 verified (= 次セッション課題)

**device-side log は RF emission の証拠にならない** (memory `feedback_verify_at_air_interface`). 以下は **air interface 越し** で取らんと確定しない:

- [ ] Mac BLE scan で `StackChan-PicoRuby` 検出
- [ ] Mac CoreBluetooth connect 成功
- [ ] NUS RX に `<F:2>\n` 書き込み → device 側 dispatcher が処理
- [ ] LCD に joy face 描画 (視認)
- [ ] LED が指定色で点灯 / blink / breathing (視認)
- [ ] SIDE=left / SIDE=right で物理的に左半分 / 右半分 が点灯 (視認、LEFT_RANGE/RIGHT_RANGE 仮定の検証)
- [ ] ACK byte (`.` or `?`) が Mac に返ってくる

---

## 3. 次セッションが最初にやるべきこと

### Step 0: 起動チェック (5分)

```bash
cd /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby
git status              # clean tree
git log --oneline main..HEAD  # 23da674 fix(application) が見える
ls /dev/cu.usbmodem*    # CoreS3 接続確認
```

### Step 1: device 側 advertise を再現 (10分)

前 session の boot.log と同じ trace が出るのを再確認。**人間に物理操作頼まない**。

1. application.mrb upload:
   ```bash
   bundle exec rake r2p2:upload_mrb SRC=mrbgems/picoruby-stackchan-protocol/examples/application.rb
   ```
   期待: `[picomodem] DONE_ACK ok`

2. serial キャプチャ起動 → 2 秒待ち → reset → 60+α 秒キャプチャ:
   ```bash
   mkdir -p tmp/longrun && rm -f tmp/longrun/recovery-step1.log
   bin/capture-with-pty 75 tmp/longrun/recovery-step1.log bundle exec rake r2p2:monitor &
   CAP_PID=$!
   sleep 4
   bundle exec rake r2p2:reset
   wait $CAP_PID
   tail -50 tmp/longrun/recovery-step1.log
   ```
   期待: 上記 §2 の verified facts と同等のログ。`heartbeat` が ~60 行出てたら run loop は 60s 維持されてる。

### Step 2: Mac BLE scan で advertise の air interface 証拠取る (10分)

device は 60s しか advertise せえへんから、**reset → 5 秒待ち → 即 scan** の順:

```bash
bundle exec rake r2p2:reset
sleep 5
cd pc/stackchan-ble-client
timeout 30 bundle exec ruby -e '
require "corebluetooth_mac"
central = CoreBluetoothMac::Central.new
devices = central.scan(name: "StackChan-PicoRuby", timeout: 20.0)
puts "found #{devices.size} device(s)"
devices.each { |d| puts "  name=#{d.name.inspect} id=#{d.identifier} rssi=#{d.rssi}" }
central.close
'
cd -
```

期待: `found 1 device(s) name="StackChan-PicoRuby" id=... rssi=-XX`

検出されたら **Phase 3 の core 機能 (advertise)** が verified。

**もし検出されんかったら**:
- Mac の Bluetooth permission を疑う (memory `feedback_claude_can_do_mac_ble_scan` 末尾)
- adv_data の bytes が間違ってないか dump して比較 (Phase 2 ble_smoke.rb の `add(AD_TYPE_COMPLETE_LOCAL_NAME, "StackChan-PicoRuby")` と同じ書き方や)
- AD_FLAGS = 0x06 と AD_TYPE_COMPLETE_LOCAL_NAME = 0x09 の order を確認
- Phase 2 ble_smoke.rb (`git show 96302fe^:mrbgems/picoruby-stackchan-protocol/examples/ble_smoke.rb`) と現 application.rb の adv 関連を diff

### Step 3: Rakefile Bundler bleed の修正 (10分、Step 4 の前提)

`r2p2:ble_control_smoke` を呼ぶ前に修正必須。前 session で発覚した issue:

- `Rakefile` 冒頭の `require "bundler/setup"` が project-root Gemfile を bind
- `:ble_control_smoke` task 内の `Dir.chdir(pc/stackchan-ble-client) { system('bundle', 'exec', ...) }` で **parent bundler env が child を汚染**
- 子プロセスで `LoadError: cannot load such file -- stackchan_ble_client`

修正: `Bundler.with_unbundled_env` で `Dir.chdir` ブロックを囲む。前 session でいったん適用→ user 指示で revert (理由: M5Stack 側 root cause を先に切り分けたかった)。今は M5Stack 側が verify されたので、Bundler fix を入れて smoke 通せる状態に持っていく。

```ruby
# Rakefile の :ble_control_smoke 内、Dir.chdir の前に Bundler.with_unbundled_env を被せる
Bundler.with_unbundled_env do
  Dir.chdir(File.expand_path('pc/stackchan-ble-client', __dir__)) do
    ok = system('bundle', 'exec', 'exe/stackchan-ble-control',
                '--side', side, 'combo', '--face', face, '--led', "#{color} #{mode}")
    unless ok
      exit $?.exitstatus
    end
  end
end
```

verify: `bundle exec rake -T r2p2:` で task list 出力するだけ (実機投げない)。

### Step 4: smoke 1 発、ACK まで取る (10分)

```bash
bundle exec rake r2p2:ble_control_smoke COLOR=red MODE=blink FACE=joy SIDE=both AUTOSTART_WAIT=12
```

期待:
- upload_mrb → DONE_ACK ok
- reset → autostart 待ち
- stackchan-ble-control connect → `<F:2>\n` 送信 → ACK `.` 受信 → `<L:1,R:255,G:0,B:0,S:B,M:b>\n` 送信 → ACK `.` 受信
- `[smoke] PASS — face=joy LED=red blink (side=both)`
- **人間に LCD / LED 視認依頼** (これだけは claude code で代替不可)

### Step 5 以降: 残りのバリエーション (LEFT/RIGHT、4 face、4 mode)

Plan の Task 18 Step 3-5 をそのまま (前 handoff の plan を参照)。視認は人間。

---

## 4. application.rb の連続稼働化は別 task

現状 60s で advertise window 切れる → shell に戻る (puts "start returned (60s elapsed)") → device は idle。production 用途には不十分。

候補 (**実証外、検証必要**):
- `loop { peri.start(60_000) }` — 60s ごとに再 enter (advertise 瞬断リスク未測定)
- `peri.start(N)` で N を大きく — どこまで安全か picoruby-ble 実装読まんとわからん

これは **Step 1-5 の smoke が green になってから別 task** で扱う。先に短命でも E2E 通す方が validation の手数が小さい。

---

## 5. 既知 pitfall / 既存メモリの再掲

memory に既にある重要事項。次セッション起動時に auto-load される:

- `feedback_verify_handoff_assumptions_first` — **本 session の最大教訓**
- `feedback_claude_can_do_mac_ble_scan` — 人間外注しない
- `feedback_verify_at_air_interface` — device log は RF 証拠にならない
- `feedback_mac_corebluetooth_gatt_cache_trap` — 0 services キャッシュ詐欺
- `feedback_apple_corebluetooth_gap_gatt_filter` — discoverServices(nil) で 0x1800/0x1801 除外
- `project_picoruby_ble_heartbeat_tick_one_second` — heartbeat は ~1s/tick
- `project_ble_phase3_partial_2026_05_17` — 本 session 末の state snapshot
- `feedback_local_commit_autonomy_bash0c7_only` — local commit は user 承認不要

---

## 6. Phase 3 完了条件 (再掲、handoff §6 と同じ)

1. ✓ Plan の Task 1-19 全部 commit 済み (Task 17/18 は本 session で部分達成)
2. ✓ 全 host unit tests green (ble-client 51 / led 47 / protocol 57)
3. ✓ `rake r2p2:build_flash` 通った (Task 17 済み)
4. [ ] **Mac scan で device 検出** (Step 2)
5. [ ] **`rake r2p2:ble_control_smoke` が exit 0** (Step 3-4)
6. [ ] **視認 (user)**: LCD joy / LED red blink 両側
7. [ ] SIDE=left / SIDE=right で物理的に正しい半分
8. [ ] 4 face / 4 mode 視認
9. ✓ `pc/stackchan-protocol/` 削除済み (Task 11)
10. [ ] PR open

3 / 10 残り 7 件。core は **Step 2 (Mac scan が当たるか)** で確定する。

---

## 7. 前 handoff doc との関係

`docs/superpowers/specs/2026-05-17-ble-phase3-execution-handoff.md` は **§5 Draft assumption #2 が外したのが原因で本 session が苦戦した**。同 doc の §0 起動 prompt、§1-3 (state snapshot / 実装フロー) は基本そのまま有効。§5 Draft assumption の表だけ要注意 — `0xFFFFFFFF` も未実証で同じ罠の可能性。

**次セッションはこの bug-recovery handoff を起点** にして、前 handoff は §1-3 (現状把握) と §6 (DoD) の参考として残す。
