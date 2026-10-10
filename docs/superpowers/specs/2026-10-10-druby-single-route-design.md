# controller と robot の間は dRuby over BLE の 1 本

`bash0C7/stackchan-picoruby` issue #19 の設計。

## 目的

Mac・iPhone・Apple Watch の controller と robot の間を流れるもの (命令・応答・頭タッチ・音声) を、robot の dRuby service 内の pair (`6e400004` write / `6e400005` notify) の 1 本にする。例外の経路は無い。

## 形

app の DSL (`apps/*/app.rb`) と `Session` の公開メソッドは経路に依らない。

### robot (`mrbgems/picoruby-stackchan-robot`、`app.mrb` に同梱)

- GATT 表は GAP、dRuby service (RX / TX と TX の CCCD だけ)、末尾の Service Changed (service `0x1801`、characteristic `0x2A05` indicate + CCCD) から成る。
- `Remote` が front。`command` / `servo` / `led` / `face` / `text` / `torque` / `read_pos` / `stack_free` / `selftest` / `touches` / `audio_begin` / `audio_chunk` / `audio_play` / `audio_done` を持つ。
- 命令系は `Dispatcher#handle_to` を通し、行の Array を返す (1 行目が `.` か `?`、あれば 2 行目が detail)。
- `touches`：`Ticker#poll_touch` は zone を `Remote` の queue (上限 16、溢れたら古い方を捨てる) に積む。`touches` は溜まった zone の Array を返して空にする。robot 側の `on_touch` handler は robot の中で走る。
- 音声：`audio_begin(n)` が buffer を空にし、`audio_chunk(bytes)` が足して受けた合計 byte 数を返し、`audio_play` は再生を予約して即座に返す。再生は reply を出し終えた後の `LinkLoop#tick` で行う (reply を待たせない)。`audio_done` は再生が済んでいれば `true`。
- `LinkLoop` は `DrbChannel#service` が dRuby pair の CCCD write か request を受けた時刻から `release_after` 経つと central を切る。

### controller (`mrbgems/picoruby-stackchan-controller`)

- `Central` の命令送信 (`send` / `raw_send` / `keepalive`) は dRuby の呼び出し。1 行目が `?` なら `DeviceError`、reply が 3 s 来なければ `TimeoutError`、robot 側の例外は `DeviceError`。`last_detail_frame` は 2 行目。
- connect は dRuby pair とその TX の CCCD だけを要求する。
- `raw` verb は frame の文字列を `FrameParser` で Hash にして `command` に渡す。
- keepalive は `touches` の呼び出しで、held の間 1 s ごと。返った zone を `Link#touches` に積む。`quiet` では呼ばない。
- `Session#speak_audio(ulaw)` は `audio_begin` → 2048 B ずつ `audio_chunk` → `audio_play` → 再生時間 (`n / 8` ms + 無音 tail 400 ms + 余裕 600 ms) 待ってから `audio_done` を `true` になるまで 500 ms 間隔で問う (上限は `Central#audio_done_timeout_ms`)。`Session#say` と built-in `speak_audio` は同じ経路を通る。
- CLI の `remote` verb は front を直接呼ぶ口。1 行目が `?` なら exit 1、busy は exit 8。

### acceptance (`acceptance/runner.rb`)

- 計測は `servo` / `face` / `led` / `text` を各 `@rounds` 回。
- `say` は 1 回流して byte 数を確かめる。
- 接続にかかった時間 (`stackchan status` の `last_connect_ms`) を timings に残す。

## 確かめ方

- host：`test/device` (Remote・Ticker・LinkLoop・DrbChannel・Dispatcher 等、`peripheral.rb` 以外の robot gem) と `test/pc` (`FakeRobotRadio` が robot gem の `Remote` と `DRbBle::Responder` を本物のまま通し、GATT 表は dRuby の pair だけ)。
- iOS / watchOS：Simulator で build し `-StackchanBatch "actions"` が `[batch] end` に届く。
- 実機：`acceptance:check` の 1 回。Service Changed・音声・touch の poll はここで初めて robot に当たる。
