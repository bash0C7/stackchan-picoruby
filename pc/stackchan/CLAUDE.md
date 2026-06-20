# pc/stackchan 規律

## Mac CoreBluetooth quirks

- **GATT cache trap**: macOS は CoreBluetooth で GATT structure を peripheral address ごとに**永続キャッシュ**。一度「0 services」が cache されると Bluetooth module reset でもクリアされず、device が正しい services を advertise しても Mac 側は 0 services のまま見続ける。Mac 側開発と並行して **iPhone nRF Connect 等の外部 scanner で device の GATT を必ず検証**して、Mac の cache 状態と device-side bug を切り分ける。
- **GAP/GATT filter**: Apple (Mac/iOS) は `CBPeripheral.discoverServices(nil)` の結果から GAP (0x1800) と GATT (0x1801) を**自動 filter**して返す。0x2A00 (Device Name characteristic) を探す道は塞がれてるので、device 名は **scan response advertisement の name** から取る。application-level services のみが discovered list に出る前提で書く。
- **Device name 切り詰め**: Mac CoreBluetooth は long device name の suffix を切り詰め/cache する。base name を短く固定し、`--name-prefix` で prefix match する設計が安全 (epoch suffix で個体識別する design は機能しない)。

## Wire format quirks

- **色は HSB packed (0xHHSSBB) で送る**、RGB ではない。`H=255°, S=0, B=0` を含む値 (e.g. `0xFF0000` を RGB のつもりで渡す) は HSB として解釈されて黒になる。CLI / SDK 側で named symbol から HSB packed への変換を必ず通す。
- **Wire char L/R は StackChan の左右と逆**: device firmware は wire 上 "L" = operator から見て右手 = StackChan の左手 という変換を内部で吸収する。SDK 側 `Stackchan::BLE::FrameCodec::SIDE_TO_CHAR` で `:left` → `"R"` / `:right` → `"L"` に正規化済み。外から触る場合はこのレイヤーを通すこと。

## Ruby 4.0 signal trap context は Mutex を使えない

Ruby 4.0 の signal trap context (`Signal.trap(sig) { ... }` のブロック内) から `Mutex#synchronize` や内部で lock を取る API を呼ぶと `ThreadError: can't be called from trap context`。**回避**: trap block 内では `Thread.new { 本処理 }` で別 thread に deferral する。`Stackchan::Daemon#install_signal_handlers` がこの pattern。

## Keep-alive boundary

`Stackchan::Daemon` は **持続接続を保ち、idle で落とさない** 設計 (spec §8 確定)。`stackchan stop` で明示的に terminate するまで生存。BLE idle 切断 (Mac CoreBluetooth ~15-20s 経験値) は今は能動的に予防していない (`stackchan-voice` 時代と同じ lazy reconnect な前提) — もし常駐対話で切断問題が出たら daemon 側に keep-alive (idempotent `<torque:on>` 等を 10s 周期で送る) を入れる判断軸:

- **継続 (現在の路線)** → keep-alive 入れない。BLE 切断時は `stackchan` 次回起動で再接続
- **応答 latency budget < 1s の対話 interface (例: Mac AI 対話)** → keep-alive 必須
- **firmware Service Changed characteristic (UUID 0x2A05)** が出るまでは GATT cache trap で daemon は永続的に復帰不能 → 検出時は人間 power-cycle 要請の ERROR ログを出して待つ

## CLI surface (stackchan verbs)

```
stackchan status              # daemon + BLE 状態
stackchan stop                # daemon 明示停止
stackchan face <name>         # neutral / smile / joy / surprised / sad / angry
stackchan led <side> <color> <mode>
                              # side: left / right / both, color: red/green/.../white/off, mode: solid/blink/breathing/off
stackchan servo --yaw-left N --yaw-right N --pitch-up N --time MS --velocity V
                              # yaw-left と yaw-right は排他 (両指定で yaw-left wins)
stackchan torque on|off       # サーボ通電
stackchan selftest            # yaw ±10 raw nudge (alive check)
stackchan say "text" [--gain F] [--voice V]
                              # macOS say → 8kHz mu-law → BLE
stackchan chat "text" [--no-speak]
                              # Apple FM 返答 + face/text 字幕、default 発話あり
stackchan touch listen [--react]
                              # 頭タッチ event 観察、--react で AI 反応
stackchan calibrate [--align-only] [--samples N] [--format ruby|json|env]
                              # daily startup は --align-only。anchor recal は 5-pose
stackchan tui                 # interactive remote control
stackchan raw "<frame>"       # ad-hoc frame
```

実行は `cd pc/stackchan && bundle exec exe/stackchan <verb>`。初回起動時に daemon (`exe/stackchand`) が auto-spawn、socket `/tmp/stackchan-#{uid}.sock` 経由で永続接続を共有する。
