# Claude Code → StackChan BLE notification bridge — design

**Date:** 2026-05-17
**Status:** approved (推奨案 across the board, user delegated decisions)
**Branch:** `feature/claude-code-notification-bridge`

## Goal

Claude Code の hook event (Notification / Stop / SubagentStop / PreToolUse の 4 種) を、
低レイテンシで StackChan の face + LED 表現に変換する **一方向通知ブリッジ** を作る。
本 repo の BLE NUS スタック (frame protocol + face render + LED animator) の **実用例** と位置づけ、
README の Feature matrix は変更しない (subsystem の追加ではなく、既存機能の use-case)。

## Non-goals (v1)

- StackChan → Mac 方向の通知 (一方向のみ、receiver は出さない)
- 複数 StackChan 同時制御 (1 daemon = 1 device)
- イベント FIFO の保証 (集中時は latest-wins drain で間引く)
- launchd autostart (起動は手動 / 後付け予定、daemon 自体は long-running として書く)
- Default mapping を code に持つこと (全部 hook command 引数で指定する設計)

## High-level architecture

```
┌─────────────────────────────────────┐
│ Claude Code (per-session, short)    │
│   hook fires (4 events)             │
└──────────────┬──────────────────────┘
               │ exec, stdin = hook JSON
               ▼
┌─────────────────────────────────────┐
│ stackchan-notify CLI (~50ms)        │ ← hook 設定の引数で face/HSB/mode/side 指定
│   1. DRbObject.new_with_uri         │   thin client、BLE には触らん
│   2. ts.write([:notify, ...])       │
│   3. exit                           │
└──────────────┬──────────────────────┘
               │ DRb over Unix socket
               │ (drbunix:/tmp/stackchan-notifier-<uid>.sock)
               ▼
┌─────────────────────────────────────────────────────────┐
│ stackchan-notifier-daemon (long-running)                │
│                                                          │
│  ┌─────────────────────┐    ┌──────────────────────┐   │
│  │ TupleSpace4Ractor   │◄──►│ BLE Worker Thread    │   │
│  │ (Ractor + Rinda)    │    │ - holds 1 BLE conn   │   │
│  │ - write/take/read   │    │ - latest-wins drain  │   │
│  │ - DRb-exposed       │    │ - auto-reconnect     │   │
│  └─────────────────────┘    └──────────┬───────────┘   │
└─────────────────────────────────────────┼───────────────┘
                                          │ stackchan-ble-client (combo frame)
                                          ▼
                              ┌───────────────────────┐
                              │ StackChan (CoreS3)    │
                              │ BLE NUS Peripheral    │
                              └───────────────────────┘
```

## Component responsibilities

### `pc/stackchan-notifier/` (new gem in this repo)

新規 sibling gem。`pc/stackchan-ble-client` を `path:` 依存。

| Component | Type | Responsibility |
|---|---|---|
| `StackchanNotifier::TupleSpace4Ractor` | vendored from [seki/ts4r](https://github.com/seki/ts4r) | Ractor 内 `Rinda::TupleSpace` を Ractor::Port 経由で操作する thin wrapper。`write/take/read` メソッド提供。MIT 表記 + 出所コメント |
| `StackchanNotifier::Worker` | Thread | TupleSpace から `[:notify, face, hsb, mode, side]` を take、latest-wins drain、`StackchanBleClient::Client#send` で 1 frame combo 送信。BLE 切断検知で reconnect backoff |
| `exe/stackchan-notifier-daemon` | process | `TupleSpace4Ractor` を生成 → `DRb.start_service('drbunix:...', ts)` → `Worker` 起動 → signal trap で graceful shutdown |
| `exe/stackchan-notify` | CLI | optparse で `--face/--hsb/--mode/--side` 受け、DRbObject 経由で `ts.write([:notify, ...])` → exit。BLE には触らん |

### Existing components (touched read-only)

- `pc/stackchan-ble-client/` — `StackchanBleClient::Client.new(...).connect.send {|s| ...}` をそのまま使う。本 gem からは変更しない
- `mrbgems/picoruby-stackchan-protocol/` — device 側は無変更 (既存 NUS combo frame で受ける)

## TupleSpace tuple shape

唯一の tuple kind:

```ruby
[:notify, face_sym, hsb_int, mode_sym, side_sym]
```

| Field | Type | Domain | Notes |
|---|---|---|---|
| `:notify` | Symbol | constant | tuple kind discriminator |
| `face_sym` | Symbol | `:neutral / :smile / :joy / :surprised` (FaceTable と一致) | nil 不可 |
| `hsb_int` | Integer | `0x000000..0xFFFFFF` (HSB 24-bit) | `StackchanBleClient::HsbToRgb` が変換 |
| `mode_sym` | Symbol | `:solid / :blink / :breathing / :off` | nil 不可 |
| `side_sym` | Symbol | `:left / :right / :both` | nil 不可 |

将来 face/color/mode が増えた場合も tuple shape は変えず、値の domain を広げるだけで対応する。

### Take pattern

Worker は `[:notify, Symbol, Integer, Symbol, Symbol]` を pattern として `take` する。
Rinda の type-pattern マッチで shape validation 兼用。

## DRb transport

- URI: `drbunix:/tmp/stackchan-notifier-<uid>.sock`
  - `<uid>` = `Process.uid` を 10 進数で。複数ユーザーの同居 Mac 干渉防止
  - `/tmp` は再起動で消える前提 (`File.unlink` を boot 時にも実行して stale socket 掃除)
- Exposed object: `TupleSpace4Ractor` インスタンスそのもの
- Access pattern (CLI 側):
  ```ruby
  DRb.start_service  # client mode (URI 指定なし)
  ts = DRbObject.new_with_uri(URI)
  ts.write([:notify, :smile, 0x55FF80, :solid, :both])
  ```
- 認証: Unix socket file の permission 0600 (owner only) で間接的に保護。Mac 単一ユーザー前提なので追加 ACL は付けない

## CLI: `stackchan-notify`

### Synopsis

```
stackchan-notify [--face NAME] [--hsb HEX] [--mode NAME] [--side NAME]
                 [--socket PATH] [--quiet]
```

### Options

| Option | Default | Domain | Notes |
|---|---|---|---|
| `--face` | required | `neutral / smile / joy / surprised` | symbol 化して tuple へ |
| `--hsb` | required | hex string like `0x55FF80` or `55FF80` | `Integer(v, 16)` でパース |
| `--mode` | required | `solid / blink / breathing / off` | |
| `--side` | `both` | `left / right / both` | |
| `--socket` | `/tmp/stackchan-notifier-<uid>.sock` | path | env `STACKCHAN_NOTIFIER_SOCKET` でも override |
| `--quiet` | false | flag | hook 失敗で stderr 抑制したいとき |

### Behavior

- 必須 option 欠如 → `abort` (非 0 exit)
- DRb 接続失敗 (`DRb::DRbConnError`) → `--quiet` 指定時は exit 0、未指定は stderr に 1 行警告 + exit 0
  - **理由:** hook の失敗が Claude Code 自体の動作を阻害してはならない。daemon 未起動 / Mac BT off でも Claude Code は普通に動くべき
- 成功 → exit 0、stdout 何も出さない (hook output は Claude UI に出るため静か)

### stdin の扱い

Claude Code は hook JSON を stdin に流す。**v1 は完全に無視** (mapping は CLI 引数で済むため)。
将来 JSON 中の `prompt_text` 等で表現変えたくなったら option 拡張。

## Daemon: `stackchan-notifier-daemon`

### Synopsis

```
stackchan-notifier-daemon [--device-name NAME] [--name-prefix PREFIX]
                          [--socket PATH] [--log-level LEVEL]
```

### Options

| Option | Default | Notes |
|---|---|---|
| `--device-name` | `StackChan-PicoRuby` (env `BLE_DEVICE_NAME` で override) | exact match |
| `--name-prefix` | nil | prefix match モード (`stackchan-ble-control` と同じ) |
| `--socket` | `/tmp/stackchan-notifier-<uid>.sock` | |
| `--log-level` | `info` | `debug / info / warn / error` |

### Boot sequence

1. `File.unlink(socket_path)` で stale socket 掃除 (ENOENT は無視)
2. `ts = TupleSpace4Ractor.new`
3. `DRb.start_service("drbunix:#{socket_path}", ts)`
4. `Worker.new(ts, ble_client_factory).start` で worker thread 起動
5. `Signal.trap("INT") / .trap("TERM")` で `@shutdown = true` を set → main thread join
6. Worker thread 内で `@shutdown` を毎 iteration チェック、true で BLE disconnect + thread 終了

### Shutdown

- SIGINT / SIGTERM → graceful shutdown (BLE 切断 → DRb stop → socket 削除 → exit 0)
- SIGKILL → DRb / socket は次回 boot 時の `File.unlink` で回収

## BLE Worker

### Main loop

```ruby
loop do
  break if @shutdown
  tuple = ts.take([:notify, Symbol, Integer, Symbol, Symbol])  # blocking
  tuple = drain_latest(ts, initial: tuple)                     # latest-wins drain
  break if @shutdown
  send_to_ble(tuple)                                            # combo frame
end
```

### `drain_latest`

```ruby
def drain_latest(ts, initial:)
  current = initial
  loop do
    extra = begin
      ts.take([:notify, Symbol, Integer, Symbol, Symbol], 0)   # timeout=0
    rescue Rinda::RequestExpiredError
      nil
    end
    break unless extra
    current = extra
  end
  current
end
```

**意図:** PreToolUse 連発で 100 件 tuple が溜まっても、BLE 1 send で最新だけ反映。
古い tuple は黙って捨てる (ログには debug level で出す)。

### Reconnect backoff

BLE 切断検知 (`StackchanBleClient::ConnectionError` または `send` 中の `Errno::*`) →

```
attempt 1: sleep 1s,  reconnect
attempt 2: sleep 2s
attempt 3: sleep 4s
attempt 4: sleep 8s
attempt 5+: sleep 30s (cap)
```

Reconnect 中に取り出した tuple は **drop** (latest-wins と同じく古い情報は捨てる)。
Reconnect 成功で counter リセット。

Mac sleep → wake で disconnect が発火するが、同じ経路で復帰する (専用処理なし)。

### `send_to_ble`

```ruby
client.send do |s|
  s.face(face_sym)
  s.led(:hsb, hsb_int, side: side_sym, mode: mode_sym)
end
```

`StackchanBleClient::Client#send` は内部で ACK 待ち、`TimeoutError` を投げる可能性あり。
TimeoutError は `ConnectionError` と同じく reconnect 経路に流す (BLE 通信が劣化してる兆候)。

## Default hook configuration (example)

`~/.claude/settings.json` (もしくは project local) に以下を追加:

```jsonc
{
  "hooks": {
    "Notification": [{
      "matcher": "",
      "hooks": [{
        "type": "command",
        "command": "stackchan-notify --face surprised --hsb 0xFF0000 --mode blink --side both --quiet"
      }]
    }],
    "Stop": [{
      "matcher": "",
      "hooks": [{
        "type": "command",
        "command": "stackchan-notify --face smile --hsb 0x00FF00 --mode solid --side both --quiet"
      }]
    }],
    "SubagentStop": [{
      "matcher": "",
      "hooks": [{
        "type": "command",
        "command": "stackchan-notify --face joy --hsb 0xFFFF00 --mode breathing --side both --quiet"
      }]
    }],
    "PreToolUse": [{
      "matcher": "Bash",
      "hooks": [{
        "type": "command",
        "command": "stackchan-notify --face neutral --hsb 0xFFA500 --mode blink --side both --quiet"
      }]
    }]
  }
}
```

これは **README の sample** として提示。code には焼かない。ユーザーが色 / face / mode 自由に差し替え可能。

## Error handling matrix

| Failure | Layer | Behavior |
|---|---|---|
| Daemon not running | CLI | `DRb::DRbConnError` → `--quiet` なら silent exit 0、否なら stderr 1 行 |
| Socket permission denied | CLI | stderr 警告 + exit 0 (Claude を止めない) |
| Invalid `--face` etc. | CLI | optparse `abort` で exit 非 0 (設定ミスは表に出す) |
| BLE device not found (initial connect) | Worker | reconnect backoff loop に入る。tuple は溜まる / drain される |
| BLE ACK timeout | Worker | reconnect 経路へ |
| Mac BT off | Worker | scan が空、reconnect backoff |
| TupleSpace.take stuck | (起きない) | drain は timeout=0、initial take は blocking で OK |
| DRb server crash | Daemon | top-level rescue で log → exit 非 0、launchd 化したら respawn |

## Testing strategy

実機接続なしで以下を完結させる:

### Unit tests (test-unit, host Ruby)

- `TupleSpace4Ractor` — write/take/read、type-pattern マッチ、Ractor 越えの値受け渡し
- `Worker#drain_latest` — 1 個 / 複数 / 0 個 (drain なし) の 3 ケース
- `Worker` main loop — fake `Client` (sendable double) を注入、tuple 受信で send 呼ばれること、reconnect backoff のスケジューリング
- CLI `stackchan-notify` — optparse 検証、--hsb の hex パース、DRb 接続失敗時の挙動

### Integration tests (daemon process)

- 別プロセスで `stackchan-notifier-daemon` 起動 (fake BLE transport 注入は env で切替)
- `stackchan-notify` CLI を sub-process で叩いて tuple が届くこと
- SIGTERM で graceful shutdown して socket が消えること

### Skipped (要実機)

- 実 CoreS3 への BLE 経路、connect/reconnect 実機挙動、Mac sleep/wake 挙動

→ ここが「実機要る直前で止まる」境界。

## File layout

```
pc/stackchan-notifier/
├── stackchan_notifier.gemspec
├── Gemfile                                  # path: ../stackchan-ble-client
├── Rakefile                                 # rake test
├── README.md                                # 起動 / hook 設定 / トラブルシュート
├── exe/
│   ├── stackchan-notifier-daemon            # long-running process
│   └── stackchan-notify                     # hook 駆動 CLI
├── lib/
│   ├── stackchan_notifier.rb                # autoload
│   └── stackchan_notifier/
│       ├── version.rb
│       ├── tuple_space4ractor.rb            # vendored from seki/ts4r (MIT)
│       ├── worker.rb                        # BLE worker thread
│       ├── cli.rb                           # notify CLI lib
│       └── daemon.rb                        # daemon entry lib
└── test/
    ├── helper.rb                            # require test-unit, fake BLE transport
    ├── tuple_space4ractor_test.rb
    ├── worker_test.rb
    ├── cli_test.rb
    └── daemon_integration_test.rb
```

## Out of scope (v1)

- launchd plist 自動生成 — README で plist 例だけ示す
- 通知の rate-limit / dedup (latest-wins drain で十分)
- StackChan → Mac 通知 (受信側 NUS TX subscribe)
- 複数 device サポート
- mDNS / discovery 自動化
- Web UI / dashboard

## References

- [seki/ts4r](https://github.com/seki/ts4r) — TupleSpace4Ractor 原典 (MIT, 関 将俊)
- [Programming with a DJ controller, not vibe coding (m_seki)](https://speakerdeck.com/m_seki/programming-with-a-dj-controller-not-vibe-coding) — latest-wins drain 等の設計判断の出典
- `docs/superpowers/handoff-2026-05-17-next-features-face-color-led-side.md` — 元の handoff (本 doc は別枠の use-case として並走)
- `mrbgems/picoruby-stackchan-protocol/` — device 側 frame protocol
- `pc/stackchan-ble-client/` — host 側 BLE 経路

## Stopping point (実機接続前)

以下まで実装 + テスト → コミット → 実機検証は次セッション以降:

1. ✅ Gem scaffold + dependencies
2. ✅ TupleSpace4Ractor vendored + tested
3. ✅ Worker w/ fake BLE + drain tested
4. ✅ CLI w/ optparse + DRb mock tested
5. ✅ Daemon integration tested (2 process, fake BLE)
6. ✅ README + hook sample

未実装で残すもの:
- 実 CoreS3 wire test
- 実 Mac sleep/wake 検証
- launchd plist
