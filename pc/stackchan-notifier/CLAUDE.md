# pc/stackchan-notifier 規律

## Ruby 4.0 signal trap context は Mutex を使えない

Ruby 4.0 の signal trap context (`Signal.trap(sig) { ... }` のブロック内) から `Mutex#synchronize` や内部で lock を取る API (`Rinda::TupleSpace#write` 等) を呼ぶと `ThreadError: can't be called from trap context`。

**回避**: trap block 内では `Thread.new { 本処理 }` で別 thread に deferral する。spawn された thread は normal context で走るので freely lock 取れる。

```ruby
Signal.trap("INT") { Thread.new { stop } }
```

test teardown で trap を戻す時は `Signal.trap("INT", "DEFAULT")` / `Signal.trap("TERM", "DEFAULT")`。

## Keep-alive boundary

現行 notifier は **lazy reconnect on notify** 設計。BLE idle 切断は能動的に予防せず、次の send が失敗した時に retry slot が `ensure_connected` → 再送信して吸収する。hook 用途 (Notification / Stop / PreToolUse 等の sporadic 発火) ではこれで充分、keep-alive は over-engineering。常時 keep-alive 通信は battery / RF 帯域の無駄。

**新規 use case で keep-alive 検討する判断軸**:

- **継続 (notifier 現行路線)** → keep-alive 入れない。retry slot + SIGHUP 手動回復で運用
- **応答 latency budget < 1s の対話 interface (例: Mac AI 対話)** → keep-alive 必須。A 案 (daemon → device NUS ping 周期送信) または C 案 (peripheral → indicate 周期) を設計に組み込む
- **firmware Service Changed characteristic (UUID 0x2A05)** が出るまでは GATT cache trap で daemon は永続的に復帰不能 → 検出時は人間 power-cycle 要請の ERROR ログを出して待つ (worker.rb の `GATT_CACHE_TRAP_PATTERN` 実装済み)
