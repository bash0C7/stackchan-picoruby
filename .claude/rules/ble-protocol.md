---
paths:
  - "mrbgems/picoruby-drb-ble/**"
  - "mrbgems/picoruby-stackchan-protocol/**"
  - "mrbgems/picoruby-stackchan-controller/**"
  - "mrbgems/picoruby-stackchan-robot/**"
  - "apps/**"
  - "pc/**"
---

# BLEプロトコルと実装制約

## dRuby over BLE単一経路

- controllerとrobot間の命令・応答・頭タッチ・音声はすべてdRuby over BLEを通る。robotのGATT表はdRuby pair（`6e400004` write / `6e400005` notify、Nordic UART base `6e40xxxx`）のみ持ち例外経路は無い。末尾にService Changed（`0x1801`/`0x2A05` indicate）を持つが、bondしないcentralは接続ごとにdiscoveryし直す前提でindicationは送らない。
- `mrbgems/picoruby-drb-ble`がDRbのTCP streamをそのまま180B chunkで流す。4096B超のrequestは捨てる（`DRbBle::Responder::MAX_REQUEST`）。
- frontは`StackChan::Robot::Remote`:
  - `Dispatcher#handle_to`経由: `command` / `servo` / `led` / `face` / `text` / `torque` / `read_pos` / `selftest`（行Arrayを返し、1行目が`.\n`か`?\n`、2行目がdetail）。
  - `Dispatcher`非経由: `touches`（溜まった頭タッチzone Array、上限16、返して空にする）、`stack_free`、`servo_health`、`audio_begin`/`audio_chunk`/`audio_play`/`audio_done`、`bot.remote`のhandler。
- controllerのreply待ちは3s。超過で`TimeoutError`、1行目が`?\n`かrobot側例外で`DeviceError`（`Central#remote_call`）。

## Frame語彙・姿勢・音声・CLI

- frame語彙（`command`のHash key / CLI `raw`文字列）: `yaw`は`<YL:0..100>`/`<YR:0..100>`（排他、YL優先）、`pitch`は`<PU:0..100>`（上のみ）、`timing`は`<T:ms>`か`<V:speed>`。稀に`<torque:on|off>`、`<selftest:run>`、`<read:pos>`（`calibrate`用）。
- cold-bootはtorque OFF+`Face::Closed`。正面に合わせて`<torque:on>`する。
- **位置detailの意味**: `<YL_actual:N,PU_actual:N>`（右向き`<YR_actual:N,PU_actual:N>`）は**受信時点の姿勢**（移動後ではない）。`unknown`=キャリブレーション要。移動後の値には`<read:pos>`（`<yaw_raw:N,pitch_raw:N>`）か次コマンドのdetailを使う。CLI `raw` verbはdetailを捨てて`OK raw`だけ返す。
- **audio**: `audio_begin`→2048Bずつ`audio_chunk`→`audio_play`（予約だけして返り、reply送出後の次`LinkLoop#tick`で再生）→再生時間（`n/8` ms+400ms+600ms）待って`audio_done`を500msごとにpoll。上限は`3300 + N*6/5` ms（30s〜180sにclamp、`Central#audio_done_timeout_ms`）。
- **CLIとController engine**:
  - built-in actionは`connect`/`status`/`stop`/`raw`/`calibrate`/`speak_audio`（`Controller::BUILTINS`）。`remote`/`touch`/`tui`はCLI専用verb（`CLI::BUILTIN_VERBS`）。
  - face名は`angry / joy / neutral / sad / smile / surprised`（`FrameCodec::FACE_INDICES`）。`closed`はBLE indexを持たず`<torque:off>`で出る。
  - exit code: `6`=calibration needed、`7`=verify fail、`8`=busy（別centralが握っているか到達不能、次actionでだけ再接続試行）。
  - `stackchan remote servo YL=50 PU=30 T=500`はfront直接呼び出し（1行目`?`でexit 1）。`stackchan touch listen --count N --timeout SEC`は`touch zone=N (back|right|left)`を出しN回でexit 0、timeoutまたはlink解放でexit 1。

## 周期・状態機械・スレッド・計測

- **周期**: robot link loop 20ms（`LinkLoop::TICK_MS`）、touch/LED poll 50ms（`Ticker`）、Mac daemon 250ms（`Daemon::TICK_MS`）、iOS/watchOS 1s。
- **Link状態機械（`Link`: `released → held → quiet` / `busy`）**:
  - robotはcentralのMTU交換完了（`0xB5`）から計測し、dRuby pairのCCCD writeとdRuby通信が`release_after`（15s）無ければ切断する。MTU交換しないcentralは通信まで見えない（Apple各OSは必ず交換）。
  - controllerは最初のactionで接続し`held`、held中だけ1sごとに`touches`を呼ぶkeepalive、最終actionから`c.hold` msで`quiet`（keepalive停止しrobot解放を待つ）。切断packet（`[0x3E,0x01,0x05]`）をdrainで見たら`released`へ。link生存中のACK timeoutはlinkを捨てない。keepalive ACK timeoutで喪失未確認なら`quiet`へ。`touch listen` poll中はhold延長。
  - connectはdRuby TXのCCCDを要求し、discovery完了前に見つからなければ`ConnectionError`→`busy`（exit 8、`Central#resolve_handles`）。
- **event drainとthread安全性**:
  - `pop`の結果に関わらず毎tick `_event_popped`を呼ぶ。`BLE#start`はoverrideしない。
  - btstack/NimBLE threadとmain taskが同時にmruby heapを触るとcrashする。device main taskは`picoruby-ble` event queueの`pop`と`pop_write_value`からのみ受け取る（`peripheral.rb`）。
- **環境切り分け・計測**:
  - Mac BLE検証は`stackchan` CLIで自律実行する（人にiPhoneを頼まない）。scanで見えない・古いGATT表を使う時は`sudo pkill bluetoothd`。
  - BLE検証中にserial monitorを並走させない（port openのDTR/RTSでdeviceがresetする）。
  - レイテンシは同一セッション内2点でのみ比較する（セッション間で15〜25%ぶれる）。描画コストはprimitive数に比例し`SPI#write`回数では説明できない。計測は`tools/latency_baseline.zsh`+`tools/latency_summary.rb`、face別は`tools/face_profile.zsh`。
