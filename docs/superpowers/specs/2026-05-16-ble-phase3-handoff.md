# BLE Phase 3 Handoff (2026-05-16)

stackchan-picoruby の BLE 軸、Phase 2 (Mac autonomous BLE verify loop + NUS bring-up) を完了し、PR 2 本を origin に open した時点での次セッション引き継ぎ。

## Phase 2 finishing state (前提)

### PR (どちらも `bash0C7` の自分のリポジトリ、自分で merge)

- **stackchan-picoruby#1** — `feat(ble): Phase 2 Mac autonomous BLE verification loop` — `feature/ble-bringup` → `main`
- **rb-corebluetooth-mac#1** — `fix(subscribe): purge only the matching characteristic on unsubscribe` (+ README docs) — `fix/subscription-purge-per-characteristic` → `main`

両 PR は CI を持たない (Mac BLE permission を CI で握れないため意図的に local-only)。merge 判断は自分で。Phase 3 を始める前に **両方 merge することを推奨** (フォローアップ作業の base を綺麗にしておく)。

### 完了している capability

- `rake r2p2:ble_verify` → CoreS3 への .mrb 上書き、reset、`stackchan-ble-verify` まで一発で走り、9 phase 通って `[verify] PASS` で `exit 0`
- exit code は machine-parseable (`2` adapter / `3` timeout / `4` connection / `5` assertion / `9` 未捕捉)、`[FAIL] phase=… reason=… domain=…` 1 行 stderr
- 端末側: `mrbgems/picoruby-stackchan-protocol/examples/ble_smoke.rb` で GAP advertise + 0xFFE0/0xFFE1 read + Nordic UART Service (RX write / TX notify)
- Mac 側: `pc/stackchan-protocol/exe/stackchan-ble-verify` (~140 行、9 phase 直列)

### 未対応として log してあるもの (rb-corebluetooth-mac 側)

`/Users/bash/dev/src/github.com/bash0C7/rb-corebluetooth-mac/request_from_stackchan-picoruby.md` を参照:

- **P0**: `path:` source 経由で gem を載せた consumer は prebuilt `corebluetooth_mac.bundle` の Ruby ABI と一致する Ruby (現状 `4.0.3`) に pin しないと load 時 crash する。load-time check か README 追記が要望として残っている (今回 PR には README 追記だけ入った、ext load 時自動 detection は別 PR)。
- **P1**: gem の runtime dependency `swift_gem` が rubygems.org に未公開。consumer Gemfile に `gem 'swift_gem', path:` 追加が必要 (README に追記済み)。発行は user の rubygems アカウントが要るので、Phase 3 と独立に対応。

これらは Phase 3 を進める前にやってもいいし、後回しでもいい。

## Phase 3 scope オプション

優先順位は付けてある。**A から始めるのを推奨**。

### A. `stackchan-ble-control` CLI 本実装 (推奨、~1 セッション)

Phase 2 の元 spec ([`2026-05-16-ble-mac-autonomous-verification-loop-design.md`](./2026-05-16-ble-mac-autonomous-verification-loop-design.md) の "Out of scope / followup") で deferred されてた sub-command CLI。

要件案:
- `bundle exec stackchan-ble-control led <COLOR> <MODE>` で NUS RX に `led red solid\n` 等のフレームを書き、TX notify で ACK/応答を待ってから exit
- 既存 `pc/stackchan-protocol/exe/stackchan-control` が USB-serial 版で同じ frame protocol を実装済み。**frame protocol は共有して transport だけ swap する** のが筋 (DRY)
- 想定 sub-command: `led`, `face`, `move`, `say`, `status`, あと一般 `raw <bytes>` (debug 用)
- exit code: stackchan-ble-verify と同じ structured failure (adapter/timeout/connection/protocol-error)
- 端末側 ble_smoke.rb は demo 用、production は `mrbgems/picoruby-stackchan-protocol/examples/main.rb` (USB-serial dispatcher) を BLE 版に置き換える/共有させる必要あり

検証は次の rake task で:
- `rake r2p2:ble_control_smoke COLOR=red MODE=blink` で upload + reset + BLE control 一連の E2E PASS が exit 0

このオプションが Phase 4 (AI bridge) の前提になる。

### B. AI bridge (rb-foundation-model-mac → stackchan-ble-control)

`/Users/bash/dev/src/github.com/bash0C7/rb-foundation-model-mac` (Apple Foundation Model の Ruby binding) を使い、Mac 側 LLM で「センサ値読む → 振る舞いを決める → サーボ/LED コマンドを送る」を Ruby で組む。

要件:
- A 完了後に着手 (BLE control が CLI として呼べる前提)
- LLM 出力を frame に翻訳する layer
- 暫定 prompt + tool spec の設計が要る (brainstorming 必須)

### C. WebSocket bridge / Web Bluetooth 主 path

[[mac-communication-path]] memory に書いてある通り、長期的には Web Bluetooth + WebSocket bridge が主検証経路。Mac CoreBluetooth は副。

Phase 3 で取り組むなら:
- WebSocket server を Mac 側 Ruby で立てる
- ブラウザ側で Web Bluetooth から CoreS3 に接続、frame を WS 経由で Mac Ruby に転送
- もしくは逆向き (Mac Ruby が WS server、ブラウザは subscriber)

Mac 側 BLE を Phase 2 で十分動かしたので、これは新しい transport 試験。A/B より優先度は低い。

### D. ble_smoke.rb → production main.rb 統合

`ble_smoke.rb` は bring-up 用の薄い demo。production は USB-serial 用の `main.rb` dispatcher と相乗りさせるべき。BLE transport を `main.rb` の I/O 層に挟む形 (frame source 抽象化)。これは A のサブタスクとして自然に発生する。

## 推奨セッション開始 prompt

次セッション、`/Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby` で開いて以下を渡せばすぐ着手できる:

> stackchan-picoruby BLE Phase 3 を始める。前段の Phase 2 (NUS + Mac autonomous verify loop) は完了して PR open 済み。引き継ぎは `docs/superpowers/specs/2026-05-16-ble-phase3-handoff.md` を読んで。
>
> 今回は Phase 3 オプション A (`stackchan-ble-control` CLI 本実装) から進めたい。
>
> 既存の `pc/stackchan-protocol/exe/stackchan-control` (USB-serial) と frame protocol を共有して、BLE 版を NUS RX/TX 経由で動かす。`rake r2p2:ble_control_smoke COLOR=red MODE=blink` 等で E2E PASS まで通すこと。
>
> 詳細仕様は brainstorming → spec → plan → subagent 駆動で進めて。

Phase 3 を B/C/D で開始したい場合は上の prompt を差し替える。

## 必読 reference (次セッション)

### このリポジトリ内

- [`docs/superpowers/specs/2026-05-16-ble-mac-autonomous-verification-loop-design.md`](./2026-05-16-ble-mac-autonomous-verification-loop-design.md) — Phase 2 の spec、"Out of scope / followup" 節に Phase 3 候補
- [`docs/superpowers/plans/2026-05-16-ble-mac-autonomous-verification-loop.md`](../plans/2026-05-16-ble-mac-autonomous-verification-loop.md) — Phase 2 の plan (8 task)
- [`pc/stackchan-protocol/exe/stackchan-ble-verify`](../../../pc/stackchan-protocol/exe/stackchan-ble-verify) — Phase 2 検証 CLI、Phase 3 BLE control の参考実装
- [`pc/stackchan-protocol/exe/stackchan-control`](../../../pc/stackchan-protocol/exe/stackchan-control) — USB-serial 版 CLI、frame protocol を BLE 版で共有する
- [`pc/stackchan-protocol/exe/picomodem-upload`](../../../pc/stackchan-protocol/exe/picomodem-upload) — Ruby + uart の自前 uploader (Python 禁止ルール準拠)
- [`mrbgems/picoruby-stackchan-protocol/examples/ble_smoke.rb`](../../../mrbgems/picoruby-stackchan-protocol/examples/ble_smoke.rb) — device 側 BLE demo (NUS 含む)
- [`mrbgems/picoruby-stackchan-protocol/examples/main.rb`](../../../mrbgems/picoruby-stackchan-protocol/examples/main.rb) — device 側 USB-serial dispatcher、Phase 3 D で BLE 統合候補
- [`Rakefile`](../../../Rakefile) — `r2p2:*` task 一式、Phase 3 で `r2p2:ble_control_smoke` 追加候補
- [`CLAUDE.md`](../../../CLAUDE.md) — プロジェクト規律 (PicoRuby 制約、rake subagent ルール、物理 op は人間に振る、`.mrb` upload 経路、bring-up シーケンス finding 等)

### 関連リポジトリ

- `/Users/bash/dev/src/github.com/bash0C7/rb-corebluetooth-mac` (path:local 想定)
  - `README.md` — Phase 2 で path source 利用要件 + Apple GAP/GATT filter limitation を明記済み
  - `request_from_stackchan-picoruby.md` — 未対応 request (P0 native ext load-time check, P1 swift_gem publish)
- `/Users/bash/dev/src/github.com/bash0C7/R2P2-ESP32` (path:local 想定、submodule で picoruby 本体)
  - `sdkconfigs/cores3`, `sdkconfigs/bt_btstack`, `sdkconfig.defaults` — CoreS3 用 (QUAD PSRAM 8MB / 16MB Flash / COEX disable 必須)
- `/Users/bash/dev/src/github.com/bash0C7/rb-foundation-model-mac` — Phase 3 B (AI bridge) の前提
- `/Users/bash/dev/src/github.com/picoruby/picoruby` — PicoRuby 本体、互換性確認用

### memory (claude code 起動時に自動 load される)

- `feedback_apple_corebluetooth_gap_gatt_filter` — `discoverServices(nil)` で 0x1800/0x1801 が出てこない件
- `project_picoruby_ble_heartbeat_tick_one_second` — heartbeat 周期 ~1s/tick (POLLING_UNIT_MS は 100ms じゃない)
- `project_ble_phase2_complete` — Phase 2 完了状態
- `feedback_mac_corebluetooth_gatt_cache_trap` — `sudo pkill bluetoothd` で復旧
- `feedback_verify_at_air_interface` — device-side log だけでは証拠不十分

## Phase 3 で踏むかもしれない落とし穴 (memory に書いたもの以外)

- **持続的な BLE 接続**: Phase 2 verify は connect → 操作 → 即 disconnect の短命接続。Phase 3 control CLI も同じパターンで OK だが、「複数 command を 1 接続で連続実行したい」要件が出てきたら Mac CoreBluetooth の ~15-20s idle disconnect window が再び問題になる。device 側で keep-alive notify を流すか、tx_ch.subscribe したまま reply を待つ設計が要る。
- **frame protocol の同期点**: USB-serial 版 `stackchan-control` は line-buffered ACK で同期している。NUS では TX notify の最大長 = ATT MTU - 3 = (Mac 側典型) 182 byte。長文 frame は分割が要る。`rb-corebluetooth-mac` の `Peripheral#max_write_length` で確認できる。
- **Mac CoreBluetooth permission の terminal-binding**: Phase 2 で見た通り、permission は実行する terminal app プロセスごと。session 切り替え (例: Cursor → iTerm) で再プロンプトに当たる。CI/sandbox 環境では使えない。
- **upload と shell の relentless 衝突**: 既存 finding 通り、autostart `app.mrb` が STDIN を独占すると uploader handshake が通らない。Phase 3 で control CLI を `peri.start(timeout)` で時間制限ループにするなら、最初の数秒は escape hatch (sleep_ms 2000 など) を入れ続ける。loop に入ったら STX 検知で抜ける hatch も要検討。
- **scope discipline**: Phase 3 で「USB serial 版 dispatcher にも手を入れたくなる」誘惑がある。Phase 3 の goal が BLE control なら USB serial 改修は別 PR にする。CLAUDE.md の `Scope Discipline` に従う。

## ハードウェア状態 (Phase 2 終了時点)

- CoreS3: `/dev/cu.usbmodem1101`、bluetoothd 再起動 + USB 抜き差し + monitor で /home/app.mrb 削除 → clean に upload できる状態
- `/home/app.mrb` には Phase 2 最終版 `ble_smoke.rb` の bytecode が載っている (advertise as `StackChan-PicoRuby` 60s)
- Mac CoreBluetooth permission: 当該 terminal に grant 済み (Cursor / iTerm / VSCode 等、Phase 3 セッションで使う terminal は新規 grant が要る場合がある)
- `bash0C7/R2P2-ESP32` の sdkconfig は `sdkconfigs/cores3` + `sdkconfigs/bt_btstack` 適用済み、`sdkconfig.defaults` は 16MB Flash + Main task stack 8192

## 次セッションの最初の 5 分

1. このファイルと `docs/superpowers/specs/2026-05-16-ble-mac-autonomous-verification-loop-design.md` を読む
2. PR merge 状況を `gh pr list` で確認 (両 PR とも merge してから着手推奨)
3. `git checkout main && git pull` で両 repo を main 最新へ
4. Phase 3 のオプションを user に確認 (A 推奨だが、B/C/D に切り替える可能性あり)
5. brainstorming skill で要件詰めへ
