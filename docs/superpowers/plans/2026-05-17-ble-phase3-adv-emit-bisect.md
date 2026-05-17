# Phase 3 BLE adv emit bisect Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to walk this plan task-by-task. Each task is a single variant + iter cycle.

**Goal:** application.rb が Mac scan で見えへん原因(adv emit を殺す要素)を bisect で特定し、production application.rb から取り除く

**Architecture:** Forward differential bisection。control = `/tmp/ble_smoke.rb` (HIT 確認済) を ground truth に、application.rb の差分グループを **1 個ずつ削った variant** を作って upload + Mac scan で HIT/MISS 判定。バイナリ的に絞り込む。

**Tech Stack:** PicoRuby on R2P2-ESP32 (CoreS3) / picoruby-ble (BTstack vendored) / rb-corebluetooth-mac (Mac side scan) / rake r2p2:upload_mrb + reset サイクル

---

## 既知の事実(plan の前提)

| variant | 結果 | 信頼性 |
|---|---|---|
| ble_smoke.rb (full, 3 svc) | HIT (-54 rssi) | ✅ 2026-05-17 再確認 |
| ble_smoke_no_diag (0xFFE0 抜き) | MISS | ✅ |
| application.rb (production) | MISS | ✅ |
| application_no_led_tick | MISS | ✅ `@led.tick` は犯人ちゃう |
| application_no_hb_puts | MISS | ✅ `puts` は犯人ちゃう |
| application_with_diag (0xFFE0 追加) | MISS | ✅ 0xFFE0 単体では足りん |

**残る容疑者**(application.rb が ble_smoke に対して持ってる差分のうち未検証):
1. **Cold-boot block** (lines 30-109): AXP2101 8×I2C, AW9523 7×I2C, SPI/ILI9342/PY32/LED init, Face::Neutral draw
2. **追加 require 7 個**: spi, gpio, i2c, machine, ili9342, py32-io-expander, stackchan-led, stackchan-protocol
3. **`initialize(display:, led:)` kwargs**(super 前に @display = display, @led = led を ivar 設定)
4. **Dispatcher / parser / ack_queue ivar 構築**(super 前に StackchanProtocol::Dispatcher.new / FrameParser.new)
5. **5s escape hatch**(vs ble_smoke の 2s)

## Bisect strategy

- 各 task は `application.rb` から 1 グループ削った variant を作る(`/tmp/app_v<N>_*.rb`)
- 上から「最も疑わしい」順に試す(cold-boot block が圧倒的に疑わしい:I2C/SPI 大量 + メモリ消費 + Face draw)
- HIT したらその瞬間に犯人確定 → 取り除く patch を production application.rb に当てて終わり
- 全部 MISS なら最終手段として ble_smoke ベースに 1 個ずつ足していく逆 bisect に切り替え

## 共通テスト手順(各 task 内で再利用)

```bash
# device clean → upload → reset → 12s wait → Mac scan 30s
cd /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby && \
  bundle exec rake r2p2:wipe_storage && \
  sleep 15 && \
  bundle exec rake r2p2:upload_mrb SRC=/tmp/<variant>.rb && \
  bundle exec rake r2p2:reset && \
  sleep 14 && \
  cd pc/stackchan-ble-client && \
  bundle exec ruby -e '
    require "corebluetooth_mac"
    c = CoreBluetoothMac::Central.new
    devs = c.scan(name: "StackChan-PicoRuby", timeout: 30)
    puts "found #{devs.size} device(s)"
    devs.each { |d| puts "  - name=#{d.name.inspect} id=#{d.identifier} rssi=#{d.rssi}" }
  '
```

upload で `FILE_ACK got nil` 出たら CLAUDE.md の fallback 階層に従う:
1. 1 回 retry (sleep 10 後)
2. ダメなら `rake r2p2:build_flash` で完全再 flash (5-10 min)
3. それでもダメなら停止してユーザーに振る

## subagent 呼び方

各 task の "Run" は **subagent (general-purpose, haiku) foreground**。Bash timeout=600000ms 指定。report は「DONE_ACK あり / reset sent / scan found N device(s) と detail」のみ要求(余計な分析禁止)。

---

### Task 1: Cold-boot block 削除 variant

**仮説**: cold-boot の大量 I2C 書込 + SPI + Face draw が BLE init と何か競合してる(メモリ・タスク・タイミング)。

**Files:**
- Create: `/tmp/app_v1_no_coldboot.rb`

- [ ] **Step 1: Variant 作成**

`/tmp/application_with_diag.rb` をベースに(GATT 構造は問題切り分け済なので 0xFFE0 入りでも入りでもどっちでもよいが、application.rb production と差分極小にしたいので **0xFFE0 入れない application.rb production** をベースにする)。

具体的に application.rb から以下を **全部削除** + 代替:
- 8 個の require のうち `'ble'` 以外全部削除
- pre-class block (line 22-109) 全部削除
- `StackChanApp.new(display: display, led: led)` を `StackChanApp.new` に変更
- `initialize(display:, led:)` を `initialize` に変更し、@display/@led 参照箇所を全部削除(`@led.tick`、`Dispatcher.new(display:, led:)` 含む)
- `@dispatcher`, `@parser`, `@ack_queue` ivar 構築は **残す**(これは別 task で切り分け)、ただし @display/@led は nil 渡す
- `sleep_ms 5000` は `sleep_ms 2000` に短縮(ble_smoke と揃える、ただし subagent timing 影響しないように)

```ruby
# 冒頭
require 'ble'
require 'stackchan-protocol'  # Dispatcher/FrameParser のため

sleep_ms 2000

# class StackChanApp < BLE ... end は production application.rb の class body そのままコピー
# ただし initialize は引数なしに変更 + @display/@led を nil で初期化:
class StackChanApp < BLE
  # ...定数群そのまま...
  def initialize
    @display = nil
    @led     = nil
    @adv_data = build_adv_data
    db = build_gatt_database
    @db = db
    @rx_handle = nus_handle(db, NUS_RX_CHAR_UUID, :value_handle)
    @tx_handle = nus_handle(db, NUS_TX_CHAR_UUID, :value_handle)
    @tx_cccd_handle = nus_handle(db, NUS_TX_CHAR_UUID, BLE::CLIENT_CHARACTERISTIC_CONFIGURATION)
    @notify_enabled = false
    @parser = StackchanProtocol::FrameParser.new
    @ack_queue = ""
    @dispatcher = StackchanProtocol::Dispatcher.new(display: @display, led: @led, stdout: self)
    super(:peripheral, db.profile_data)
  end
  # write, build_adv_data, build_gatt_database, nus_handle, packet_callback (puts つき OK), heartbeat_callback (@led.tick だけ guard で `if @led` 化), flush_one_ack 全部そのまま
end

peri = StackChanApp.new
peri.debug = true
peri.start(60_000)
```

- [ ] **Step 2: Variant を upload + scan**

Run subagent (general-purpose, haiku, timeout 600000):
```
cd /Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby && \
  bundle exec rake r2p2:wipe_storage && sleep 15 && \
  bundle exec rake r2p2:upload_mrb SRC=/tmp/app_v1_no_coldboot.rb && \
  bundle exec rake r2p2:reset && sleep 14 && \
  cd pc/stackchan-ble-client && \
  bundle exec ruby -e 'require "corebluetooth_mac"; c=CoreBluetoothMac::Central.new; devs=c.scan(name:"StackChan-PicoRuby",timeout:30); puts "found #{devs.size} device(s)"; devs.each{|d| puts "  - rssi=#{d.rssi}"}'
```

期待: DONE_ACK 出る、reset sent 出る、scan 結果 0 or 1+ device。

- [ ] **Step 3: 分岐判定**

| 結果 | 次のアクション |
|---|---|
| HIT (found 1+) | **cold-boot block が犯人**。Task 5 (production patch) に飛んで application.rb から cold-boot 削除 + LCD/LED は別 task や別ファイルに切り出す方針確定 |
| MISS (found 0) | cold-boot は単独犯ではない。Task 2 (Dispatcher ivar 切り分け) に進む |

---

### Task 2: Dispatcher / parser / ack_queue ivar 削除 variant

**仮説**: super 前の Dispatcher / FrameParser construction が何か(GC pressure・memory layout・class load timing)で BLE init を壊す。

**前提**: Task 1 が MISS だった(cold-boot 単独犯やない)。

**Files:**
- Create: `/tmp/app_v2_no_dispatcher.rb`

- [ ] **Step 1: Variant 作成**

`/tmp/app_v1_no_coldboot.rb` をベースに、`@parser` / `@ack_queue` / `@dispatcher` の ivar 構築 3 行を削除。`require 'stackchan-protocol'` も削除可。heartbeat_callback / write / packet_callback で `@parser` / `@dispatcher` 参照箇所を nil-guard 化:

```ruby
# initialize から削除:
# @parser = StackchanProtocol::FrameParser.new
# @ack_queue = ""
# @dispatcher = StackchanProtocol::Dispatcher.new(...)

# heartbeat_callback の rx_data 処理を nil-guard 化:
def heartbeat_callback
  rx_data = pop_write_value(@rx_handle)
  while rx_data
    # @parser.feed(rx_data).each { |frame| @dispatcher.handle(frame) }  # DISABLED
    rx_data = pop_write_value(@rx_handle)
  end
  cccd = pop_write_value(@tx_cccd_handle)
  @notify_enabled = (cccd == "\x01\x00") if cccd
end
```

- [ ] **Step 2: Variant を upload + scan**

同じ subagent 呼び出し(SRC のみ `/tmp/app_v2_no_dispatcher.rb`)。

- [ ] **Step 3: 分岐判定**

| 結果 | 次のアクション |
|---|---|
| HIT | **Dispatcher/parser/ack_queue ivar 構築が犯人**。super 前の StackchanProtocol::* インスタンス化が何か壊してる。Task 5 で production fix(lazy init / 別 thread / 別タイミング)を計画 |
| MISS | これも単独犯ちゃう。Task 3 (要件 minimum 化) に進む |

---

### Task 3: ble_smoke の class body そのままコピー(最小再現)

**仮説**: ここまで MISS が続いてたら、もう application.rb の class body そのものに問題ある。ble_smoke の class body をそのまま使い、cold-boot もなし、kwargs もなし、Dispatcher もなしの **完全 ble_smoke 互換** に戻す。これが HIT すれば「これ以降足したもの」のどれかが犯人と確定。MISS なら upload/reset/scan 自体の信頼性疑う(再 build_flash も視野)。

**前提**: Task 2 まで MISS。

**Files:**
- Create: `/tmp/app_v3_ble_smoke_clone.rb`

- [ ] **Step 1: ble_smoke.rb をそのまま `/tmp/app_v3_ble_smoke_clone.rb` にコピー**

```bash
cp /tmp/ble_smoke.rb /tmp/app_v3_ble_smoke_clone.rb
```

(これは sanity test。Step 1 の Task 1 制御群は既にやってるので、ここで再度 HIT 出ないなら test pipeline の問題)

- [ ] **Step 2: 上記 subagent 呼び出しで upload + scan**

- [ ] **Step 3: 分岐判定**

| 結果 | 次のアクション |
|---|---|
| HIT | test pipeline 健在、application のどっかに犯人いる(逆 bisect 開始 = Task 4) |
| MISS | **test pipeline 問題** = device 物理状態 / Mac 側 / 直前 wipe の影響などを疑う。停止してユーザーと相談 |

---

### Task 4: 逆 bisect — ble_smoke に application 要素を 1 個ずつ追加(必要なら)

**仮説**: Task 1-3 で割れんかった場合のみ。`/tmp/app_v3_ble_smoke_clone.rb` (HIT 確定) に application 要素を 1 group ずつ足して MISS に転ぶ瞬間を捉える。

**前提**: Task 3 で HIT 確認できた = test pipeline 信頼可能。Task 1-2 で個別群削除しても MISS = 複数要素の組合せが原因。

**Sub-task 4a**: `/tmp/app_v3` + 5s escape hatch + 全 require → 検証
**Sub-task 4b**: 4a に cold-boot block 追加 → 検証
**Sub-task 4c**: 4b に kwargs initialize 追加 → 検証
**Sub-task 4d**: 4c に Dispatcher ivar 追加 → 検証

各 sub-task は 1 variant + 1 検証サイクル。MISS に転んだ瞬間の追加分が犯人。

- [ ] **Step 1: Sub-task 4a 実施**(variant 作成 + 検証 + 判定)
- [ ] **Step 2: Sub-task 4b 実施**(必要なら)
- [ ] **Step 3: Sub-task 4c 実施**(必要なら)
- [ ] **Step 4: Sub-task 4d 実施**(必要なら)

---

### Task 5: production application.rb への fix 適用

**前提**: Task 1-4 のいずれかで犯人特定済。

- [ ] **Step 1: 犯人グループに応じた production patch を application.rb に当てる**

| 犯人 | patch 方針 |
|---|---|
| cold-boot block | application.rb から削除 → 別 `app.rb` / boot init 分離(または BLE init を cold-boot 前に持ってくる) |
| Dispatcher ivar | super の **後** に lazy init する形にリファクタ |
| kwargs / @display @led | initialize から外して setter で後付け |
| 複数要素の組合せ | 該当全部を順番に処理 |

- [ ] **Step 2: 修正後の production application.rb を upload + scan で HIT 確認**

- [ ] **Step 3: Commit**

```bash
git add mrbgems/picoruby-stackchan-protocol/examples/application.rb
git commit -m "fix(application): <犯人内容> to restore BLE adv emission"
```

- [ ] **Step 4: 次の handoff (Step 4 = ble_control_smoke ACK) に進む準備**

`docs/superpowers/specs/2026-05-17-ble-phase3-bug-recovery-handoff.md` の Step 4 (E2E ACK) に進むため、本 plan は完了。memory 更新:
- 犯人 fact を `project_ble_phase3_*.md` 系に上書き
- 否定済 hypothesis memory は削除 or 否定 fact として更新

---

## 期待される所要時間

- Task 1-3 各 3-5 min (variant 作成 1 min + upload+scan 2-4 min) × 3 = **15 min**
- Task 4 sub-task 各 3-5 min × 0-4 = **0-20 min**(必要なら)
- Task 5 patch + verify + commit = **10 min**
- **合計 25-45 min**(build_flash failover 入ったら +10 min)
