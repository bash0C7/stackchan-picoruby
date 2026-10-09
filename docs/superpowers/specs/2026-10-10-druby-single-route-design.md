# dRuby over BLE を唯一の経路にする

`bash0C7/stackchan-picoruby` issue #19 の設計。

## 目的

Mac・iPhone・Apple Watch の controller と robot の間を流れるものを、dRuby over BLE (`6e400004` write / `6e400005` notify) の 1 本にする。音声だけは両方の経路を持ち、実機で測ってからどちらを残すか決める。

## 形

app の DSL (`apps/*/app.rb`) と `Session` の公開メソッドは変えない。変わるのは `Session` の下。

### robot (`mrbgems/picoruby-stackchan-robot`、`app.mrb` に同梱)

- `Remote` が front。`command` / `servo` / `led` / `face` / `text` / `torque` / `read_pos` / `stack_free` に `selftest` / `touches` / `audio_begin` / `audio_chunk` / `audio_play` / `audio_done` を足す。
- 命令系は今と同じく `Dispatcher#handle_to` を通し、text link が notify するはずだった行の Array を返す (1 行目が `.` か `?`、あれば 2 行目が detail)。
- `touches`：`Ticker#poll_touch` は zone を notify せず `Remote` の queue (上限 16、溢れたら古い方を捨てる) に積む。`touches` は溜まった zone の Array を返して空にする。robot 側の `on_touch` handler は今のまま robot の中で走る。
- 音声の dRuby 経路：`audio_begin(n)` が buffer を空にし、`audio_chunk(bytes)` が足して受けた合計 byte 数を返し、`audio_play` は再生を予約して即座に返す。再生は reply の notify を出し終えた後の `LinkLoop#tick` で行う (reply を待たせない)。`audio_done` は再生が済んでいれば `true`。
- NUS RX (`6e400002`) が受けるのは `<A:N>` と、それに続く音声の byte 列だけ。それ以外の frame には `?` を返す。NUS TX が出すのは `<A:ready>` / `<A:done>` / `?` だけ。
- GATT 表の末尾に Service Changed (service `0x1801`、characteristic `0x2A05` indicate + CCCD) を足す。

### controller (`mrbgems/picoruby-stackchan-controller`)

- `Central` の命令送信 (`send` / `raw_send` / `keepalive`) は dRuby の呼び出しになる。1 行目が `?` なら `DeviceError`、reply が 3 s 来なければ `TimeoutError` (link の状態機械が今と同じに扱えるよう、DRb の timeout をこの例外に写す)、robot 側の例外は `DeviceError`。`last_detail_frame` は 2 行目。
- `raw` verb は frame の文字列を `FrameParser` で Hash にして `command` に渡す。
- keepalive は `touches` の呼び出しで、held の間 1 s ごと。返った zone を `Link#touches` に積む。`<read:pos>` を keepalive に使わない (servo bus を無駄に叩かない)。`quiet` では呼ばない。
- `Session#speak_audio(ulaw, route: :direct)`。`:direct` は今の `<A:N>` 経路。`:drb` は `audio_begin` → 2048 B ずつ `audio_chunk` → `audio_play` → 再生時間 (`n / 8` ms + 無音 tail 400 ms + 余裕 600 ms) 待ってから `audio_done` を `true` になるまで 500 ms 間隔で問う (上限は `Central#audio_done_timeout_ms`)。`Session#say` と built-in `speak_audio` は `route:` を受ける。Mac の `say` は `--drb` flag で `:drb`。既定は `:direct`。
- CLI の `remote` verb は残す (front を直接呼ぶ口)。1 行目が `?` なら exit 1、busy は exit 8。

### acceptance (`acceptance/runner.rb`)

- 計測は `servo` / `face` / `led` / `text` を各 `@rounds` 回 (どれも dRuby)。「text 対 remote」の比較は無くなる。
- `say` を `:direct` と `:drb` で 1 回ずつ流し、所要時間と直後の `stack_free` を timings に残す。verdict には使わない (判断材料)。
- 接続にかかった時間 (`stackchan status` の `last_connect_ms`) を timings に残す。

## 決めること (実機の計測の後、owner)

音声を `:drb` に寄せるか。寄せるなら NUS の 1 組目・`AudioReceiver`・firmware の `FrameParser` 依存が消える。

## 確かめ方

- host：`test/device` (Remote・Ticker・LinkLoop・Peripheral 以外の robot gem) と `test/pc` (`FakeRobotRadio` が robot gem の `Remote` と `DRbBle::Responder` を本物のまま通す)。
- iOS / watchOS：Simulator で build し `-StackchanBatch "actions"` が `[batch] end` に届く。
- 実機：`acceptance:check` の 1 回。Service Changed・音声の両経路・touch の poll はここで初めて robot に当たる。
